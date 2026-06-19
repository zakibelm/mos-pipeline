-- =============================================================================
-- MOS v4.1-RC1 — Sprint 1 : Base Tables + Video Pipeline Infrastructure
-- =============================================================================
-- Tables  : clients, video_production_notion, image_generation_queue,
--           fal_video_queue, video_memory_notion, processing_locks,
--           alert_queue, notion_sync_events
-- Views   : fal_video_stuck_jobs, comfyui_stuck_jobs, video_costs_by_client
-- Functions: set_updated_at, acquire_processing_lock, release_processing_lock,
--            create_pipeline_alert, queue_comfyui_image, queue_fal_video,
--            mark_fal_failed, mark_comfyui_failed
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ---------------------------------------------------------------------------
-- 0. Helper trigger — updated_at
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 1. Clients (stub — base requise pour les FK)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clients (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT        NOT NULL,
  email      TEXT,
  timezone   TEXT        DEFAULT 'America/Toronto',
  is_active  BOOLEAN     DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE OR REPLACE TRIGGER trg_clients_updated_at
  BEFORE UPDATE ON clients
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 2. Enum — video_pipeline_status v4.1
--    failed_retryable / dead_letter séparés intentionnellement
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'video_pipeline_status') THEN
    CREATE TYPE video_pipeline_status AS ENUM (
      'brief_created',
      'brief_synced',
      'script_generating',
      'script_generated',
      'script_approved',
      'image_queued',
      'image_processing',
      'image_generated',
      'image_approved',
      'video_queued',
      'video_processing',
      'video_generated',
      'client_review',
      'approved_for_publish',
      'scheduled',
      'published',
      'failed_retryable',
      'dead_letter',
      'archived'
    );
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3. Table principale — video_production_notion
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS video_production_notion (
  id                  UUID                 PRIMARY KEY DEFAULT gen_random_uuid(),

  client_id           UUID                 NOT NULL REFERENCES clients(id) ON DELETE CASCADE,

  notion_page_id      TEXT                 UNIQUE,
  notion_database_id  TEXT,
  notion_url          TEXT,

  title               TEXT                 NOT NULL,
  brief               TEXT,
  objective           TEXT,
  target_audience     TEXT,
  platform            TEXT,
  format              TEXT,
  language            TEXT                 DEFAULT 'fr-CA',

  statut              video_pipeline_status DEFAULT 'brief_created',

  script_json         JSONB                DEFAULT '{}'::jsonb,
  shot_list           JSONB                DEFAULT '[]'::jsonb,
  prompt_comfyui      TEXT,
  prompt_fal          TEXT,
  negative_prompt     TEXT,

  reference_image_url TEXT,
  video_url           TEXT,
  thumbnail_url       TEXT,

  blotato_post_id     TEXT,
  scheduled_at        TIMESTAMPTZ,
  published_at        TIMESTAMPTZ,

  -- Correction 4 : coûts dès Sprint 1
  cost_openrouter_cad NUMERIC(10,4)        DEFAULT 0,
  cost_comfyui_cad    NUMERIC(10,4)        DEFAULT 0,
  cost_fal_cad        NUMERIC(10,4)        DEFAULT 0,
  cost_blotato_cad    NUMERIC(10,4)        DEFAULT 0,
  cost_total_cad      NUMERIC(10,4)        GENERATED ALWAYS AS (
    COALESCE(cost_openrouter_cad, 0)
    + COALESCE(cost_comfyui_cad, 0)
    + COALESCE(cost_fal_cad, 0)
    + COALESCE(cost_blotato_cad, 0)
  ) STORED,

  last_error          TEXT,
  version             INT                  DEFAULT 1,

  created_at          TIMESTAMPTZ          DEFAULT NOW(),
  updated_at          TIMESTAMPTZ          DEFAULT NOW()
);

CREATE OR REPLACE TRIGGER trg_video_production_updated_at
  BEFORE UPDATE ON video_production_notion
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX IF NOT EXISTS idx_video_production_client
  ON video_production_notion(client_id);

CREATE INDEX IF NOT EXISTS idx_video_production_status
  ON video_production_notion(statut);

CREATE INDEX IF NOT EXISTS idx_video_production_notion_page
  ON video_production_notion(notion_page_id);

-- ---------------------------------------------------------------------------
-- 4. Queue ComfyUI — image_generation_queue
--    Correction 1 : retry_count, max_retries, next_retry_at, last_error
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS image_generation_queue (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),

  video_id            UUID        NOT NULL REFERENCES video_production_notion(id) ON DELETE CASCADE,
  client_id           UUID        NOT NULL REFERENCES clients(id) ON DELETE CASCADE,

  comfyui_workflow_id UUID,
  comfyui_prompt_id   TEXT,

  comfyui_status      TEXT        DEFAULT 'queued' CHECK (
    comfyui_status IN ('queued', 'processing', 'completed', 'failed', 'dead_letter')
  ),

  input_payload       JSONB       DEFAULT '{}'::jsonb,
  output_payload      JSONB       DEFAULT '{}'::jsonb,
  output_image_url    TEXT,

  -- Correction 1 : retry + backoff
  retry_count         INT         DEFAULT 0,
  max_retries         INT         DEFAULT 3,
  next_retry_at       TIMESTAMPTZ,
  last_error          TEXT,

  started_at          TIMESTAMPTZ,
  completed_at        TIMESTAMPTZ,
  created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_comfyui_queue_video
  ON image_generation_queue(video_id);

CREATE INDEX IF NOT EXISTS idx_comfyui_queue_status
  ON image_generation_queue(comfyui_status);

-- Index partiel : sweeper scanne uniquement les jobs en échec
CREATE INDEX IF NOT EXISTS idx_comfyui_queue_retry
  ON image_generation_queue(next_retry_at)
  WHERE comfyui_status = 'failed';

-- ---------------------------------------------------------------------------
-- 5. Queue fal.ai — fal_video_queue
--    Correction 1 : même colonnes retry que ComfyUI
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fal_video_queue (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),

  video_id       UUID        NOT NULL REFERENCES video_production_notion(id) ON DELETE CASCADE,
  client_id      UUID        NOT NULL REFERENCES clients(id) ON DELETE CASCADE,

  fal_request_id TEXT        UNIQUE,
  fal_model      TEXT        NOT NULL,

  fal_status     TEXT        DEFAULT 'queued' CHECK (
    fal_status IN ('queued', 'processing', 'completed', 'failed', 'dead_letter')
  ),

  input_payload  JSONB       DEFAULT '{}'::jsonb,
  output_payload JSONB       DEFAULT '{}'::jsonb,

  video_url      TEXT,
  thumbnail_url  TEXT,

  -- Correction 1 : retry + backoff
  retry_count    INT         DEFAULT 0,
  max_retries    INT         DEFAULT 3,
  next_retry_at  TIMESTAMPTZ,
  last_error     TEXT,

  started_at     TIMESTAMPTZ,
  completed_at   TIMESTAMPTZ,
  created_at     TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_fal_queue_video
  ON fal_video_queue(video_id);

CREATE INDEX IF NOT EXISTS idx_fal_queue_status
  ON fal_video_queue(fal_status);

CREATE INDEX IF NOT EXISTS idx_fal_queue_request
  ON fal_video_queue(fal_request_id);

-- Index partiel : sweeper cible uniquement les failed
CREATE INDEX IF NOT EXISTS idx_fal_queue_retry
  ON fal_video_queue(next_retry_at)
  WHERE fal_status = 'failed';

-- ---------------------------------------------------------------------------
-- 6. Mémoire vidéo — video_memory_notion
--    Correction 5 : mémoire réinjectée dans les briefs
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS video_memory_notion (
  id                     UUID         PRIMARY KEY DEFAULT gen_random_uuid(),

  client_id              UUID         NOT NULL REFERENCES clients(id) ON DELETE CASCADE,

  element_type           TEXT         NOT NULL CHECK (
    element_type IN (
      'hook', 'cta', 'visual_style', 'format',
      'duration', 'caption_style', 'platform_pattern', 'negative_pattern'
    )
  ),

  element_value          TEXT         NOT NULL,
  source_video_id        UUID         REFERENCES video_production_notion(id) ON DELETE SET NULL,

  confidence_score       NUMERIC(5,2) DEFAULT 0,
  avg_engagement_rate    NUMERIC(8,4),
  avg_watch_time_seconds NUMERIC(10,2),
  usage_count            INT          DEFAULT 1,

  is_active              BOOLEAN      DEFAULT TRUE,

  created_at             TIMESTAMPTZ  DEFAULT NOW(),
  updated_at             TIMESTAMPTZ  DEFAULT NOW()
);

CREATE OR REPLACE TRIGGER trg_video_memory_updated_at
  BEFORE UPDATE ON video_memory_notion
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX IF NOT EXISTS idx_video_memory_client
  ON video_memory_notion(client_id);

-- Index composite pour la requête Script Agent (top 10 patterns gagnants)
CREATE INDEX IF NOT EXISTS idx_video_memory_active_perf
  ON video_memory_notion(client_id, is_active, avg_engagement_rate DESC NULLS LAST, confidence_score DESC);

-- ---------------------------------------------------------------------------
-- 7. Slot lock ComfyUI — processing_locks
--    Correction 3 : éviter la saturation GPU/VRAM du VPS
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS processing_locks (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id  UUID        NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  lock_type  TEXT        NOT NULL CHECK (lock_type IN ('comfyui_image', 'fal_video', 'blotato_publish')),
  locked_by  TEXT,
  locked_at  TIMESTAMPTZ DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(client_id, lock_type)
);

CREATE OR REPLACE FUNCTION acquire_processing_lock(
  p_client_id   UUID,
  p_lock_type   TEXT,
  p_locked_by   TEXT,
  p_ttl_minutes INT DEFAULT 30
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
  v_acquired BOOLEAN := FALSE;
BEGIN
  -- Purge des locks expirés avant tentative d'acquisition
  DELETE FROM processing_locks WHERE expires_at < NOW();

  INSERT INTO processing_locks (client_id, lock_type, locked_by, expires_at)
  VALUES (
    p_client_id,
    p_lock_type,
    p_locked_by,
    NOW() + (p_ttl_minutes || ' minutes')::INTERVAL
  )
  ON CONFLICT (client_id, lock_type) DO NOTHING;

  GET DIAGNOSTICS v_acquired = ROW_COUNT;
  RETURN v_acquired;
END;
$$;

CREATE OR REPLACE FUNCTION release_processing_lock(
  p_client_id UUID,
  p_lock_type TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  DELETE FROM processing_locks
  WHERE client_id = p_client_id AND lock_type = p_lock_type;
END;
$$;

-- ---------------------------------------------------------------------------
-- 8. Alert queue — alert_queue
--    Correction 6 : human-in-the-loop sur dead letter + anomalies critiques
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS alert_queue (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id   UUID        REFERENCES clients(id) ON DELETE SET NULL,
  video_id    UUID        REFERENCES video_production_notion(id) ON DELETE SET NULL,
  source      TEXT        NOT NULL CHECK (
    source IN ('notion', 'n8n', 'comfyui', 'fal', 'blotato', 'rag', 'system')
  ),
  severity    TEXT        NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
  alert_type  TEXT        NOT NULL,
  message     TEXT        NOT NULL,
  payload     JSONB       DEFAULT '{}'::jsonb,
  status      TEXT        DEFAULT 'open' CHECK (
    status IN ('open', 'acknowledged', 'resolved', 'ignored')
  ),
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  resolved_at TIMESTAMPTZ
);

-- Index partiel : routing n8n → uniquement les alertes ouvertes par sévérité
CREATE INDEX IF NOT EXISTS idx_alert_queue_open
  ON alert_queue(severity, created_at DESC)
  WHERE status = 'open';

CREATE OR REPLACE FUNCTION create_pipeline_alert(
  p_client_id  UUID,
  p_video_id   UUID,
  p_source     TEXT,
  p_severity   TEXT,
  p_alert_type TEXT,
  p_message    TEXT,
  p_payload    JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_alert_id UUID;
BEGIN
  INSERT INTO alert_queue (client_id, video_id, source, severity, alert_type, message, payload)
  VALUES (p_client_id, p_video_id, p_source, p_severity, p_alert_type, p_message, p_payload)
  RETURNING id INTO v_alert_id;
  RETURN v_alert_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 9. Log des événements Notion webhook
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS notion_sync_events (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  notion_page_id TEXT,
  raw_payload    JSONB       DEFAULT '{}'::jsonb,
  processed      BOOLEAN     DEFAULT FALSE,
  processed_at   TIMESTAMPTZ,
  created_at     TIMESTAMPTZ DEFAULT NOW()
);

-- Index partiel : n8n lit uniquement les événements non traités
CREATE INDEX IF NOT EXISTS idx_notion_sync_unprocessed
  ON notion_sync_events(created_at DESC)
  WHERE processed = FALSE;

-- ---------------------------------------------------------------------------
-- 10. Vues sweeper — Correction 2
-- ---------------------------------------------------------------------------

-- Correction 2 : jobs fal.ai bloqués > 20 min (webhook manqué)
CREATE OR REPLACE VIEW fal_video_stuck_jobs AS
SELECT *
FROM fal_video_queue
WHERE fal_status IN ('queued', 'processing')
  AND created_at < NOW() - INTERVAL '20 minutes';

-- Correction 2 : jobs ComfyUI bloqués > 15 min
CREATE OR REPLACE VIEW comfyui_stuck_jobs AS
SELECT *
FROM image_generation_queue
WHERE comfyui_status IN ('queued', 'processing')
  AND created_at < NOW() - INTERVAL '15 minutes';

-- Correction 4 : coûts agrégés par client
CREATE OR REPLACE VIEW video_costs_by_client AS
SELECT
  client_id,
  COUNT(*)                                                  AS total_videos,
  SUM(cost_total_cad)                                       AS total_cost_cad,
  AVG(cost_total_cad)                                       AS avg_cost_per_video_cad,
  SUM(CASE WHEN statut = 'published' THEN 1 ELSE 0 END)     AS published_videos
FROM video_production_notion
GROUP BY client_id;

-- ---------------------------------------------------------------------------
-- 11. Fonctions transactionnelles
-- ---------------------------------------------------------------------------

-- Correction 5 : lecture mémoire pour prompt Script Agent
-- Usage n8n : SELECT * FROM get_client_winning_patterns($1) LIMIT 10
CREATE OR REPLACE FUNCTION get_client_winning_patterns(p_client_id UUID)
RETURNS TABLE (
  element_type           TEXT,
  element_value          TEXT,
  confidence_score       NUMERIC,
  avg_engagement_rate    NUMERIC,
  usage_count            INT
)
LANGUAGE sql STABLE
AS $$
  SELECT element_type, element_value, confidence_score, avg_engagement_rate, usage_count
  FROM video_memory_notion
  WHERE client_id = p_client_id AND is_active = TRUE
  ORDER BY avg_engagement_rate DESC NULLS LAST, confidence_score DESC, usage_count DESC
  LIMIT 10;
$$;

-- Queue image ComfyUI (atomique : insert queue + update statut)
CREATE OR REPLACE FUNCTION queue_comfyui_image(
  p_video_id UUID,
  p_payload  JSONB
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_client_id UUID;
  v_queue_id  UUID;
BEGIN
  SELECT client_id INTO v_client_id
  FROM video_production_notion WHERE id = p_video_id;

  IF v_client_id IS NULL THEN
    RAISE EXCEPTION 'Video not found: %', p_video_id;
  END IF;

  INSERT INTO image_generation_queue (video_id, client_id, input_payload)
  VALUES (p_video_id, v_client_id, p_payload)
  RETURNING id INTO v_queue_id;

  UPDATE video_production_notion
  SET statut = 'image_queued', updated_at = NOW()
  WHERE id = p_video_id;

  RETURN v_queue_id;
END;
$$;

-- Queue vidéo fal.ai (atomique : insert queue + update statut)
CREATE OR REPLACE FUNCTION queue_fal_video(
  p_video_id UUID,
  p_model    TEXT,
  p_payload  JSONB
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_client_id UUID;
  v_queue_id  UUID;
BEGIN
  SELECT client_id INTO v_client_id
  FROM video_production_notion WHERE id = p_video_id;

  IF v_client_id IS NULL THEN
    RAISE EXCEPTION 'Video not found: %', p_video_id;
  END IF;

  INSERT INTO fal_video_queue (video_id, client_id, fal_model, input_payload)
  VALUES (p_video_id, v_client_id, p_model, p_payload)
  RETURNING id INTO v_queue_id;

  UPDATE video_production_notion
  SET statut = 'video_queued', updated_at = NOW()
  WHERE id = p_video_id;

  RETURN v_queue_id;
END;
$$;

-- Mark fal.ai failed : backoff 5 min → 15 min → 45 min → dead_letter + alerte
CREATE OR REPLACE FUNCTION mark_fal_failed(
  p_queue_id UUID,
  p_error    TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_retry_count INT;
  v_max_retries INT;
  v_video_id    UUID;
  v_backoff     INTERVAL;
BEGIN
  SELECT retry_count, max_retries, video_id
  INTO v_retry_count, v_max_retries, v_video_id
  FROM fal_video_queue WHERE id = p_queue_id;

  v_backoff := CASE v_retry_count
    WHEN 0 THEN INTERVAL '5 minutes'
    WHEN 1 THEN INTERVAL '15 minutes'
    ELSE         INTERVAL '45 minutes'
  END;

  IF v_retry_count + 1 < v_max_retries THEN
    UPDATE fal_video_queue
    SET
      fal_status    = 'failed',
      retry_count   = retry_count + 1,
      last_error    = p_error,
      next_retry_at = NOW() + v_backoff
    WHERE id = p_queue_id;

    UPDATE video_production_notion
    SET statut = 'failed_retryable', last_error = p_error, updated_at = NOW()
    WHERE id = v_video_id;
  ELSE
    UPDATE fal_video_queue
    SET fal_status = 'dead_letter', retry_count = retry_count + 1, last_error = p_error
    WHERE id = p_queue_id;

    UPDATE video_production_notion
    SET statut = 'dead_letter', last_error = p_error, updated_at = NOW()
    WHERE id = v_video_id;

    PERFORM create_pipeline_alert(
      NULL, v_video_id, 'fal', 'critical', 'fal_dead_letter',
      p_error,
      jsonb_build_object('queue_id', p_queue_id)
    );
  END IF;
END;
$$;

-- Mark ComfyUI failed : même logique backoff que fal.ai
CREATE OR REPLACE FUNCTION mark_comfyui_failed(
  p_queue_id UUID,
  p_error    TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_retry_count INT;
  v_max_retries INT;
  v_video_id    UUID;
  v_backoff     INTERVAL;
BEGIN
  SELECT retry_count, max_retries, video_id
  INTO v_retry_count, v_max_retries, v_video_id
  FROM image_generation_queue WHERE id = p_queue_id;

  v_backoff := CASE v_retry_count
    WHEN 0 THEN INTERVAL '5 minutes'
    WHEN 1 THEN INTERVAL '15 minutes'
    ELSE         INTERVAL '45 minutes'
  END;

  IF v_retry_count + 1 < v_max_retries THEN
    UPDATE image_generation_queue
    SET
      comfyui_status = 'failed',
      retry_count    = retry_count + 1,
      last_error     = p_error,
      next_retry_at  = NOW() + v_backoff
    WHERE id = p_queue_id;

    UPDATE video_production_notion
    SET statut = 'failed_retryable', last_error = p_error, updated_at = NOW()
    WHERE id = v_video_id;
  ELSE
    UPDATE image_generation_queue
    SET comfyui_status = 'dead_letter', retry_count = retry_count + 1, last_error = p_error
    WHERE id = p_queue_id;

    UPDATE video_production_notion
    SET statut = 'dead_letter', last_error = p_error, updated_at = NOW()
    WHERE id = v_video_id;

    PERFORM create_pipeline_alert(
      NULL, v_video_id, 'comfyui', 'critical', 'comfyui_dead_letter',
      p_error,
      jsonb_build_object('queue_id', p_queue_id)
    );
  END IF;
END;
$$;
