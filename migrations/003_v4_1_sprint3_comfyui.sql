-- =============================================================================
-- MOS v4.1-RC1 — Sprint 3 : ComfyUI Queue + Slot Lock + Image Upload
-- =============================================================================
-- Tables   : comfyui_workflows (templates JSON par style)
-- Functions: claim_next_comfyui_job, mark_comfyui_started,
--            mark_comfyui_completed, get_comfyui_processing_jobs
-- Views    : comfyui_jobs_for_poller
-- Storage  : bucket mos-images (instructions en commentaires)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. comfyui_workflows — templates ComfyUI par style visuel
--    Le n8n Submit workflow injecte positive/negative prompts dans le JSON
--    avant d'envoyer à ComfyUI VPS
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS comfyui_workflows (
  id              UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  name            TEXT    NOT NULL UNIQUE,
  description     TEXT,
  -- Clé du node positif dans le workflow JSON (ex: "6" pour SDXL base)
  positive_node_id TEXT   NOT NULL DEFAULT '6',
  -- Clé du node négatif
  negative_node_id TEXT   NOT NULL DEFAULT '7',
  -- Le workflow ComfyUI complet (format API, pas format UI)
  workflow_json   JSONB   NOT NULL,
  is_default      BOOLEAN DEFAULT FALSE,
  is_active       BOOLEAN DEFAULT TRUE,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE OR REPLACE TRIGGER trg_comfyui_workflows_updated_at
  BEFORE UPDATE ON comfyui_workflows
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Un seul workflow default à la fois
CREATE UNIQUE INDEX IF NOT EXISTS idx_comfyui_workflows_default
  ON comfyui_workflows(is_default)
  WHERE is_default = TRUE;

-- ---------------------------------------------------------------------------
-- 2. claim_next_comfyui_job — acquisition atomique du prochain job
--    FOR UPDATE SKIP LOCKED : concurrent-safe, jamais deux workers sur le même job
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION claim_next_comfyui_job(p_locked_by TEXT)
RETURNS TABLE (
  queue_id        UUID,
  video_id        UUID,
  client_id       UUID,
  retry_count     INT,
  input_payload   JSONB,
  prompt_comfyui  TEXT,
  negative_prompt TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_queue_id UUID;
  v_video_id UUID;
  v_client_id UUID;
  v_retry_count INT;
  v_input_payload JSONB;
BEGIN
  -- Sélectionne ET verrouille atomiquement le prochain job disponible
  SELECT q.id, q.video_id, q.client_id, q.retry_count, q.input_payload
  INTO v_queue_id, v_video_id, v_client_id, v_retry_count, v_input_payload
  FROM image_generation_queue q
  WHERE q.comfyui_status IN ('queued', 'failed')
    AND (q.next_retry_at IS NULL OR q.next_retry_at <= NOW())
  ORDER BY q.retry_count ASC, q.created_at ASC
  LIMIT 1
  FOR UPDATE SKIP LOCKED;

  IF NOT FOUND THEN
    RETURN; -- Rien à traiter
  END IF;

  -- Marque comme processing immédiatement
  UPDATE image_generation_queue
  SET comfyui_status = 'processing', started_at = NOW()
  WHERE id = v_queue_id;

  -- Retourne les données + les prompts depuis la vidéo liée
  RETURN QUERY
  SELECT
    v_queue_id,
    v_video_id,
    v_client_id,
    v_retry_count,
    v_input_payload,
    vpn.prompt_comfyui,
    vpn.negative_prompt
  FROM video_production_notion vpn
  WHERE vpn.id = v_video_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. mark_comfyui_started — enregistre le prompt_id retourné par ComfyUI
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mark_comfyui_started(
  p_queue_id        UUID,
  p_comfyui_prompt_id TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE image_generation_queue
  SET
    comfyui_prompt_id = p_comfyui_prompt_id,
    comfyui_status    = 'processing',
    started_at        = COALESCE(started_at, NOW())
  WHERE id = p_queue_id;

  -- Propagate statut to video
  UPDATE video_production_notion
  SET statut = 'image_processing', updated_at = NOW()
  WHERE id = (SELECT video_id FROM image_generation_queue WHERE id = p_queue_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. mark_comfyui_completed — mise à jour atomique à la fin de la génération
--    Appelé par le Poller quand /history/{prompt_id} retourne completed
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mark_comfyui_completed(
  p_queue_id       UUID,
  p_image_url      TEXT,
  p_output_payload JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_video_id UUID;
BEGIN
  SELECT video_id INTO v_video_id
  FROM image_generation_queue WHERE id = p_queue_id;

  UPDATE image_generation_queue
  SET
    comfyui_status   = 'completed',
    output_image_url = p_image_url,
    output_payload   = p_output_payload,
    completed_at     = NOW()
  WHERE id = p_queue_id;

  UPDATE video_production_notion
  SET
    reference_image_url = p_image_url,
    statut              = 'image_generated',
    cost_comfyui_cad    = COALESCE(cost_comfyui_cad, 0)
                          + COALESCE((p_output_payload->>'cost_cad')::numeric, 0),
    updated_at          = NOW()
  WHERE id = v_video_id;

  RETURN v_video_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. Vue pour le Poller — jobs ComfyUI en cours avec données vidéo
--    Inclut les jobs stuck (> 15 min) pour détection automatique
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW comfyui_jobs_for_poller AS
SELECT
  q.id                  AS queue_id,
  q.video_id,
  q.client_id,
  q.comfyui_prompt_id,
  q.retry_count,
  q.max_retries,
  q.started_at,
  q.created_at,
  NOW() - q.started_at  AS running_duration,
  CASE
    WHEN q.started_at < NOW() - INTERVAL '15 minutes' THEN TRUE
    ELSE FALSE
  END                   AS is_stuck,
  vpn.notion_page_id,
  vpn.notion_url
FROM image_generation_queue q
JOIN video_production_notion vpn ON vpn.id = q.video_id
WHERE q.comfyui_status = 'processing'
  AND q.comfyui_prompt_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- STORAGE SETUP (exécuter dans Supabase Dashboard → Storage)
-- ---------------------------------------------------------------------------
-- 1. Créer un bucket public nommé "mos-images"
-- 2. Policy INSERT : service_role uniquement
-- 3. Policy SELECT : public (pour les URLs publiques)
--
-- Via API (n8n ou curl) :
-- POST {SUPABASE_URL}/storage/v1/bucket
-- Body: { "id": "mos-images", "name": "mos-images", "public": true }
-- Headers: Authorization Bearer {SERVICE_KEY}
-- ---------------------------------------------------------------------------
