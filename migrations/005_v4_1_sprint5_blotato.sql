-- =============================================================================
-- MOS v4.1-RC1 — Sprint 5 : Blotato Publication + Planification + Audit Log
-- =============================================================================
-- Tables   : blotato_publication_log (audit trail complet)
-- Functions: log_blotato_action, mark_blotato_scheduled,
--            mark_blotato_published, get_blotato_publish_context
-- Views    : blotato_publication_stats, blotato_pending_posts
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. blotato_publication_log — audit trail de chaque appel Blotato
--    Séparé par action (upload et post_create distincts) pour rejeu partiel
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS blotato_publication_log (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  video_id          UUID        NOT NULL REFERENCES video_production_notion(id) ON DELETE CASCADE,
  client_id         UUID        NOT NULL REFERENCES clients(id) ON DELETE CASCADE,

  action            TEXT        NOT NULL CHECK (action IN (
    'media_upload',
    'post_create',
    'post_schedule',
    'post_publish',
    'post_cancel',
    'status_check'
  )),

  blotato_media_id  TEXT,
  blotato_post_id   TEXT,
  platform          TEXT,

  request_payload   JSONB       DEFAULT '{}'::jsonb,
  response_payload  JSONB       DEFAULT '{}'::jsonb,

  success           BOOLEAN     DEFAULT FALSE,
  error_msg         TEXT,
  http_status       INT,

  cost_cad          NUMERIC(10,4) DEFAULT 0,

  created_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_blotato_log_video
  ON blotato_publication_log(video_id);

CREATE INDEX IF NOT EXISTS idx_blotato_log_client
  ON blotato_publication_log(client_id, created_at DESC);

-- Index partiel pour rejeu : uploads réussis sans post_create correspondant
CREATE INDEX IF NOT EXISTS idx_blotato_log_upload_ok
  ON blotato_publication_log(video_id, blotato_media_id)
  WHERE action = 'media_upload' AND success = TRUE;

-- ---------------------------------------------------------------------------
-- 2. log_blotato_action — insère audit + met à jour cost_blotato_cad
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION log_blotato_action(
  p_video_id          UUID,
  p_action            TEXT,
  p_blotato_media_id  TEXT    DEFAULT NULL,
  p_blotato_post_id   TEXT    DEFAULT NULL,
  p_platform          TEXT    DEFAULT NULL,
  p_request_payload   JSONB   DEFAULT '{}'::jsonb,
  p_response_payload  JSONB   DEFAULT '{}'::jsonb,
  p_success           BOOLEAN DEFAULT TRUE,
  p_error_msg         TEXT    DEFAULT NULL,
  p_http_status       INT     DEFAULT 200,
  p_cost_cad          NUMERIC DEFAULT 0
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_client_id UUID;
  v_log_id    UUID;
BEGIN
  SELECT client_id INTO v_client_id
  FROM video_production_notion WHERE id = p_video_id;

  INSERT INTO blotato_publication_log (
    video_id, client_id, action,
    blotato_media_id, blotato_post_id, platform,
    request_payload, response_payload,
    success, error_msg, http_status, cost_cad
  )
  VALUES (
    p_video_id, v_client_id, p_action,
    p_blotato_media_id, p_blotato_post_id, p_platform,
    p_request_payload, p_response_payload,
    p_success, p_error_msg, p_http_status, p_cost_cad
  )
  RETURNING id INTO v_log_id;

  -- Met à jour le coût Blotato sur la vidéo uniquement si action de publication réussie
  IF p_success AND p_action IN ('post_create', 'post_schedule') AND p_cost_cad > 0 THEN
    UPDATE video_production_notion
    SET cost_blotato_cad = COALESCE(cost_blotato_cad, 0) + p_cost_cad,
        updated_at       = NOW()
    WHERE id = p_video_id;
  END IF;

  RETURN v_log_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. mark_blotato_scheduled — statut = scheduled + post_id + scheduled_at
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mark_blotato_scheduled(
  p_video_id     UUID,
  p_post_id      TEXT,
  p_scheduled_at TIMESTAMPTZ,
  p_cost_cad     NUMERIC DEFAULT 0
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE video_production_notion
  SET
    blotato_post_id  = p_post_id,
    scheduled_at     = p_scheduled_at,
    statut           = 'scheduled',
    cost_blotato_cad = COALESCE(cost_blotato_cad, 0) + p_cost_cad,
    updated_at       = NOW()
  WHERE id = p_video_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. mark_blotato_published — statut = published + published_at timestamp
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mark_blotato_published(
  p_video_id UUID,
  p_post_id  TEXT,
  p_cost_cad NUMERIC DEFAULT 0
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE video_production_notion
  SET
    blotato_post_id  = p_post_id,
    published_at     = NOW(),
    statut           = 'published',
    cost_blotato_cad = COALESCE(cost_blotato_cad, 0) + p_cost_cad,
    updated_at       = NOW()
  WHERE id = p_video_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. get_blotato_publish_context — récupère tout le contexte nécessaire
--    pour n8n en un seul appel (évite 3 requêtes séparées)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_blotato_publish_context(p_video_id UUID)
RETURNS TABLE (
  video_id            UUID,
  client_id           UUID,
  notion_page_id      TEXT,
  title               TEXT,
  platform            TEXT,
  video_url           TEXT,
  thumbnail_url       TEXT,
  script_caption      TEXT,
  script_hook         TEXT,
  script_cta          TEXT,
  scheduled_at        TIMESTAMPTZ,
  blotato_post_id     TEXT,
  statut              TEXT,
  -- Upload déjà réalisé ?
  existing_media_id   TEXT
)
LANGUAGE sql STABLE
AS $$
  SELECT
    v.id,
    v.client_id,
    v.notion_page_id,
    v.title,
    v.platform,
    v.video_url,
    v.thumbnail_url,
    -- Extraction caption depuis script_json
    COALESCE(
      v.script_json->>'caption',
      (v.script_json->'script'->>'caption')
    )                                                            AS script_caption,
    COALESCE(
      v.script_json->>'hook',
      (v.script_json->'script'->>'hook')
    )                                                            AS script_hook,
    COALESCE(
      v.script_json->>'cta',
      (v.script_json->'script'->>'cta')
    )                                                            AS script_cta,
    v.scheduled_at,
    v.blotato_post_id,
    v.statut::TEXT,
    -- Dernier media_id uploadé avec succès (pour rejeu sans réupload)
    (
      SELECT bl.blotato_media_id
      FROM blotato_publication_log bl
      WHERE bl.video_id = v.id
        AND bl.action   = 'media_upload'
        AND bl.success  = TRUE
      ORDER BY bl.created_at DESC
      LIMIT 1
    )                                                            AS existing_media_id
  FROM video_production_notion v
  WHERE v.id = p_video_id;
$$;

-- ---------------------------------------------------------------------------
-- 6. blotato_publication_stats — dashboard par client
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW blotato_publication_stats AS
SELECT
  v.client_id,
  COUNT(DISTINCT v.id)
    FILTER (WHERE v.statut = 'scheduled')                AS scheduled_count,
  COUNT(DISTINCT v.id)
    FILTER (WHERE v.statut = 'published')                AS published_count,
  SUM(v.cost_blotato_cad)                                AS total_blotato_cost_cad,
  AVG(v.cost_blotato_cad)
    FILTER (WHERE v.cost_blotato_cad > 0)                AS avg_cost_per_post_cad,
  COUNT(bl.id)
    FILTER (WHERE bl.action = 'media_upload' AND NOT bl.success) AS upload_failures,
  COUNT(bl.id)
    FILTER (WHERE bl.action IN ('post_create','post_schedule') AND NOT bl.success)
                                                          AS post_failures
FROM video_production_notion v
LEFT JOIN blotato_publication_log bl ON bl.video_id = v.id
GROUP BY v.client_id;

-- ---------------------------------------------------------------------------
-- 7. blotato_pending_posts — vidéos planifiées dont la date est passée
--    Utile pour un cron de vérification publication effective (optionnel Sprint 6)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW blotato_pending_posts AS
SELECT
  id, client_id, notion_page_id, title,
  blotato_post_id, scheduled_at, platform
FROM video_production_notion
WHERE statut       = 'scheduled'
  AND scheduled_at < NOW()
  AND blotato_post_id IS NOT NULL;
