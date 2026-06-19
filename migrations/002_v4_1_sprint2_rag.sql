-- =============================================================================
-- MOS v4.1-RC1 — Sprint 2 : RAG Context + Script Agent Support
-- =============================================================================
-- Tables   : client_contexts, script_generation_log
-- Functions: retrieve_context, update_video_statut, log_script_generation
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. client_contexts — base de connaissance RAG par client
--    Types : brand_voice, target_audience, product_info, past_performance,
--            competitor_analysis, content_guidelines
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS client_contexts (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id    UUID        NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  context_type TEXT        NOT NULL CHECK (
    context_type IN (
      'brand_voice',
      'target_audience',
      'product_info',
      'past_performance',
      'competitor_analysis',
      'content_guidelines'
    )
  ),
  title        TEXT,
  content      TEXT        NOT NULL,
  source       TEXT,
  metadata     JSONB       DEFAULT '{}'::jsonb,
  is_active    BOOLEAN     DEFAULT TRUE,
  created_at   TIMESTAMPTZ DEFAULT NOW(),
  updated_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE OR REPLACE TRIGGER trg_client_contexts_updated_at
  BEFORE UPDATE ON client_contexts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX IF NOT EXISTS idx_client_contexts_client
  ON client_contexts(client_id);

-- Index partiel : Script Agent ne lit que les contextes actifs
CREATE INDEX IF NOT EXISTS idx_client_contexts_active
  ON client_contexts(client_id, context_type, updated_at DESC)
  WHERE is_active = TRUE;

-- ---------------------------------------------------------------------------
-- 2. retrieve_context — injecte le contexte client dans le prompt Script Agent
--    Usage n8n : SELECT * FROM retrieve_context($client_id, 'brand_voice', 3)
--    Usage complet : SELECT * FROM retrieve_context($client_id) — tous types
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retrieve_context(
  p_client_id    UUID,
  p_context_type TEXT DEFAULT NULL,
  p_limit        INT  DEFAULT 5
)
RETURNS TABLE (
  context_type TEXT,
  title        TEXT,
  content      TEXT,
  metadata     JSONB
)
LANGUAGE sql STABLE
AS $$
  SELECT context_type, title, content, metadata
  FROM client_contexts
  WHERE client_id = p_client_id
    AND is_active = TRUE
    AND (p_context_type IS NULL OR context_type = p_context_type)
  ORDER BY updated_at DESC
  LIMIT p_limit;
$$;

-- ---------------------------------------------------------------------------
-- 3. script_generation_log — traçabilité des appels OpenRouter + coûts tokens
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS script_generation_log (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  video_id          UUID        NOT NULL REFERENCES video_production_notion(id) ON DELETE CASCADE,
  client_id         UUID        NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  model_used        TEXT,
  prompt_tokens     INT         DEFAULT 0,
  completion_tokens INT         DEFAULT 0,
  total_tokens      INT         DEFAULT 0,
  cost_usd          NUMERIC(10,6) DEFAULT 0,
  cost_cad          NUMERIC(10,4) DEFAULT 0,
  generation_ms     INT,
  success           BOOLEAN     DEFAULT FALSE,
  error_message     TEXT,
  created_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_script_log_video
  ON script_generation_log(video_id);

CREATE INDEX IF NOT EXISTS idx_script_log_client_cost
  ON script_generation_log(client_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- 4. log_script_generation — insère le log ET met à jour cost_openrouter_cad
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION log_script_generation(
  p_video_id          UUID,
  p_model             TEXT,
  p_prompt_tokens     INT,
  p_completion_tokens INT,
  p_cost_usd          NUMERIC,
  p_usd_to_cad_rate   NUMERIC DEFAULT 1.37,
  p_generation_ms     INT     DEFAULT NULL,
  p_success           BOOLEAN DEFAULT TRUE,
  p_error_message     TEXT    DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_client_id UUID;
  v_cost_cad  NUMERIC;
  v_log_id    UUID;
BEGIN
  SELECT client_id INTO v_client_id
  FROM video_production_notion WHERE id = p_video_id;

  v_cost_cad := p_cost_usd * p_usd_to_cad_rate;

  INSERT INTO script_generation_log (
    video_id, client_id, model_used,
    prompt_tokens, completion_tokens, total_tokens,
    cost_usd, cost_cad, generation_ms, success, error_message
  )
  VALUES (
    p_video_id, v_client_id, p_model,
    p_prompt_tokens, p_completion_tokens, p_prompt_tokens + p_completion_tokens,
    p_cost_usd, v_cost_cad, p_generation_ms, p_success, p_error_message
  )
  RETURNING id INTO v_log_id;

  -- Met à jour le coût cumulatif sur la vidéo
  IF p_success THEN
    UPDATE video_production_notion
    SET
      cost_openrouter_cad = COALESCE(cost_openrouter_cad, 0) + v_cost_cad,
      updated_at          = NOW()
    WHERE id = p_video_id;
  END IF;

  RETURN v_log_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. update_video_statut — mise à jour atomique statut + champs optionnels
--    Utilisé par n8n après chaque étape du pipeline pour éviter les race conditions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_video_statut(
  p_video_id UUID,
  p_statut   video_pipeline_status,
  p_payload  JSONB DEFAULT '{}'::jsonb
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE video_production_notion
  SET
    statut          = p_statut,
    updated_at      = NOW(),
    -- Champs script — mis à jour seulement si présents dans le payload
    script_json     = COALESCE((p_payload->>'script_json')::jsonb,    script_json),
    shot_list       = COALESCE((p_payload->>'shot_list')::jsonb,      shot_list),
    prompt_comfyui  = COALESCE(p_payload->>'prompt_comfyui',          prompt_comfyui),
    prompt_fal      = COALESCE(p_payload->>'prompt_fal',              prompt_fal),
    negative_prompt = COALESCE(p_payload->>'negative_prompt',         negative_prompt),
    -- Champs publication
    video_url       = COALESCE(p_payload->>'video_url',               video_url),
    thumbnail_url   = COALESCE(p_payload->>'thumbnail_url',           thumbnail_url),
    blotato_post_id = COALESCE(p_payload->>'blotato_post_id',         blotato_post_id),
    scheduled_at    = COALESCE((p_payload->>'scheduled_at')::timestamptz, scheduled_at),
    published_at    = COALESCE((p_payload->>'published_at')::timestamptz, published_at)
  WHERE id = p_video_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. Vue — coûts tokens Script Agent par client (dashboard Sprint 2)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW script_costs_by_client AS
SELECT
  s.client_id,
  COUNT(*)                        AS total_generations,
  SUM(s.total_tokens)             AS total_tokens,
  SUM(s.cost_cad)                 AS total_cost_cad,
  AVG(s.generation_ms)            AS avg_latency_ms,
  SUM(CASE WHEN s.success THEN 1 ELSE 0 END) AS successful,
  SUM(CASE WHEN NOT s.success THEN 1 ELSE 0 END) AS failed
FROM script_generation_log s
GROUP BY s.client_id;
