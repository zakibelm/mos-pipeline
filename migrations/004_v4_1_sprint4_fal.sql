-- =============================================================================
-- MOS v4.1-RC1 — Sprint 4 : fal.ai Async Queue + Webhook + Sweeper
-- =============================================================================
-- Note : fal_video_queue, queue_fal_video, mark_fal_failed et
--        fal_video_stuck_jobs sont déjà créés en Sprint 1.
-- Ce fichier ajoute les fonctions manquantes pour le cycle complet.
-- =============================================================================
-- Functions: mark_fal_started, mark_fal_completed,
--            get_fal_queue_by_request_id, resolve_fal_webhook
-- Views    : fal_jobs_active (sweeper), fal_dead_letter_summary
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. mark_fal_started — enregistre le request_id retourné par fal.ai
--    Appelé par Submit juste après POST queue.fal.run
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mark_fal_started(
  p_queue_id      UUID,
  p_request_id    TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_video_id UUID;
BEGIN
  UPDATE fal_video_queue
  SET
    fal_request_id = p_request_id,
    fal_status     = 'processing',
    started_at     = NOW()
  WHERE id = p_queue_id
  RETURNING video_id INTO v_video_id;

  UPDATE video_production_notion
  SET statut = 'video_processing', updated_at = NOW()
  WHERE id = v_video_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. mark_fal_completed — mise à jour atomique quand la vidéo est prête
--    Appelé par le Webhook OU le Sweeper selon quel chemin complète en premier
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mark_fal_completed(
  p_queue_id       UUID,
  p_video_url      TEXT,
  p_thumbnail_url  TEXT    DEFAULT NULL,
  p_output_payload JSONB   DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_video_id UUID;
  v_cost_cad NUMERIC;
BEGIN
  SELECT video_id INTO v_video_id
  FROM fal_video_queue WHERE id = p_queue_id;

  -- Coût injecté par n8n depuis les métadonnées fal.ai (optionnel)
  v_cost_cad := COALESCE((p_output_payload->>'cost_cad')::numeric, 0);

  UPDATE fal_video_queue
  SET
    fal_status     = 'completed',
    video_url      = p_video_url,
    thumbnail_url  = p_thumbnail_url,
    output_payload = p_output_payload,
    completed_at   = NOW()
  WHERE id = p_queue_id
    AND fal_status != 'completed'; -- idempotent : ignore si déjà complété

  UPDATE video_production_notion
  SET
    video_url     = p_video_url,
    thumbnail_url = p_thumbnail_url,
    statut        = 'video_generated',
    cost_fal_cad  = COALESCE(cost_fal_cad, 0) + v_cost_cad,
    updated_at    = NOW()
  WHERE id = v_video_id
    AND statut != 'video_generated'; -- idempotent

  RETURN v_video_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. get_fal_queue_by_request_id — lookup par request_id pour le webhook
--    fal.ai envoie request_id mais pas l'ID interne Supabase
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_fal_queue_by_request_id(p_request_id TEXT)
RETURNS TABLE (
  queue_id        UUID,
  video_id        UUID,
  client_id       UUID,
  fal_model       TEXT,
  fal_status      TEXT,
  notion_page_id  TEXT,
  retry_count     INT
)
LANGUAGE sql STABLE
AS $$
  SELECT
    q.id, q.video_id, q.client_id, q.fal_model,
    q.fal_status, vpn.notion_page_id, q.retry_count
  FROM fal_video_queue q
  JOIN video_production_notion vpn ON vpn.id = q.video_id
  WHERE q.fal_request_id = p_request_id
  LIMIT 1;
$$;

-- ---------------------------------------------------------------------------
-- 4. resolve_fal_webhook — handler unique pour webhook et sweeper
--    Logique : si completed → mark_fal_completed
--              si error → mark_fal_failed
--              sinon → no-op (let sweeper handle)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION resolve_fal_webhook(
  p_request_id    TEXT,
  p_status        TEXT,          -- 'OK' | 'ERROR' | 'COMPLETED' | 'FAILED'
  p_video_url     TEXT    DEFAULT NULL,
  p_thumbnail_url TEXT    DEFAULT NULL,
  p_error_msg     TEXT    DEFAULT NULL,
  p_output_payload JSONB  DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_queue_id UUID;
  v_video_id UUID;
  v_result   JSONB;
BEGIN
  SELECT id INTO v_queue_id
  FROM fal_video_queue WHERE fal_request_id = p_request_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('action', 'not_found', 'request_id', p_request_id);
  END IF;

  IF p_status IN ('OK', 'COMPLETED') AND p_video_url IS NOT NULL THEN
    SELECT mark_fal_completed(v_queue_id, p_video_url, p_thumbnail_url, p_output_payload)
    INTO v_video_id;
    v_result := jsonb_build_object('action', 'completed', 'video_id', v_video_id);

  ELSIF p_status IN ('ERROR', 'FAILED') THEN
    PERFORM mark_fal_failed(v_queue_id, COALESCE(p_error_msg, 'fal.ai returned error status'));
    v_result := jsonb_build_object('action', 'failed_or_retried', 'queue_id', v_queue_id);

  ELSE
    v_result := jsonb_build_object('action', 'noop', 'status', p_status);
  END IF;

  RETURN v_result;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. fal_jobs_active — vue pour le Sweeper (toutes les 30 min)
--    Inclut tous les jobs en cours, pas uniquement les stuck
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW fal_jobs_active AS
SELECT
  q.id                  AS queue_id,
  q.video_id,
  q.client_id,
  q.fal_request_id,
  q.fal_model,
  q.fal_status,
  q.retry_count,
  q.max_retries,
  q.started_at,
  q.created_at,
  NOW() - q.created_at  AS age,
  CASE
    WHEN q.created_at < NOW() - INTERVAL '2 hours'  THEN 'critical'
    WHEN q.created_at < NOW() - INTERVAL '30 minutes' THEN 'warning'
    ELSE 'ok'
  END                   AS age_status,
  vpn.notion_page_id,
  vpn.title
FROM fal_video_queue q
JOIN video_production_notion vpn ON vpn.id = q.video_id
WHERE q.fal_status IN ('queued', 'processing')
  AND q.fal_request_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 6. fal_dead_letter_summary — dashboard pour alertes humaines (Sprint 6)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW fal_dead_letter_summary AS
SELECT
  q.client_id,
  COUNT(*)                            AS dead_letter_count,
  MAX(q.created_at)                   AS last_failure_at,
  ARRAY_AGG(q.last_error ORDER BY q.created_at DESC) FILTER (WHERE q.last_error IS NOT NULL) AS errors
FROM fal_video_queue q
WHERE q.fal_status = 'dead_letter'
GROUP BY q.client_id;
