-- =============================================================================
-- MOS v4.1-RC1 — Sprint 6 : Learning Loop — KPI Ingestion + Memory Update
-- =============================================================================
-- Tables   : video_kpi_log (historique brut des métriques plateforme)
-- Functions: upsert_video_memory, ingest_video_kpis
-- Views    : learning_loop_candidates, memory_performance_summary
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Contrainte unique sur video_memory_notion (requise par upsert_video_memory)
--    Nécessaire pour ON CONFLICT DO NOTHING dans upsert_video_memory
-- ---------------------------------------------------------------------------
ALTER TABLE video_memory_notion
  ADD CONSTRAINT IF NOT EXISTS uq_video_memory_client_type_value
  UNIQUE (client_id, element_type, element_value);

-- ---------------------------------------------------------------------------
-- 1. video_kpi_log — historique brut des métriques par vidéo publiée
--    fetched_date DATE (IMMUTABLE) sert de clé pour le dédoublonnage journalier
--    (DATE_TRUNC est STABLE, interdit dans les index → colonne DATE dédiée)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS video_kpi_log (
  id                   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  video_id             UUID        NOT NULL REFERENCES video_production_notion(id) ON DELETE CASCADE,
  client_id            UUID        NOT NULL REFERENCES clients(id) ON DELETE CASCADE,

  platform             TEXT        NOT NULL,
  blotato_post_id      TEXT,

  views                BIGINT      DEFAULT 0,
  likes                BIGINT      DEFAULT 0,
  comments             BIGINT      DEFAULT 0,
  shares               BIGINT      DEFAULT 0,
  saves                BIGINT      DEFAULT 0,
  reach                BIGINT      DEFAULT 0,
  impressions          BIGINT      DEFAULT 0,
  watch_time_seconds   NUMERIC(12,2) DEFAULT 0,

  -- engagement_rate calculé — COALESCE(reach, views) comme dénominateur
  engagement_rate      NUMERIC(8,6) GENERATED ALWAYS AS (
    CASE WHEN COALESCE(reach, views, 0) > 0
    THEN (COALESCE(likes,0) + COALESCE(comments,0) + COALESCE(shares,0) + COALESCE(saves,0))::NUMERIC
         / NULLIF(COALESCE(reach, views), 0)
    ELSE 0 END
  ) STORED,

  avg_watch_pct        NUMERIC(5,2),
  raw_payload          JSONB       DEFAULT '{}'::jsonb,

  fetched_date         DATE        DEFAULT CURRENT_DATE,
  fetched_at           TIMESTAMPTZ DEFAULT NOW(),
  created_at           TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_kpi_log_video
  ON video_kpi_log(video_id);

CREATE INDEX IF NOT EXISTS idx_kpi_log_client
  ON video_kpi_log(client_id, fetched_at DESC);

-- Dédoublonnage par jour : une seule entrée par (vidéo, plateforme, jour)
CREATE UNIQUE INDEX IF NOT EXISTS idx_kpi_log_video_platform_day
  ON video_kpi_log(video_id, platform, fetched_date);

-- ---------------------------------------------------------------------------
-- 2. upsert_video_memory — met à jour ou crée un pattern dans video_memory_notion
--    Moyenne pondérée : (ancienne * count + nouvelle) / (count + 1)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION upsert_video_memory(
  p_client_id          UUID,
  p_source_video_id    UUID,
  p_element_type       TEXT,
  p_element_value      TEXT,
  p_engagement_rate    NUMERIC,
  p_watch_time_seconds NUMERIC DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_memory_id UUID;
BEGIN
  INSERT INTO video_memory_notion (
    client_id, source_video_id,
    element_type, element_value,
    avg_engagement_rate, avg_watch_time_seconds,
    confidence_score, usage_count,
    is_active
  )
  VALUES (
    p_client_id, p_source_video_id,
    p_element_type, p_element_value,
    p_engagement_rate, p_watch_time_seconds,
    LEAST(p_engagement_rate * 1000, 100),
    1,
    TRUE
  )
  ON CONFLICT (client_id, element_type, element_value) DO NOTHING
  RETURNING id INTO v_memory_id;

  -- Pattern existant : moyenne pondérée + incrémente usage_count
  IF v_memory_id IS NULL THEN
    UPDATE video_memory_notion
    SET
      avg_engagement_rate    = (avg_engagement_rate * usage_count + p_engagement_rate)
                               / (usage_count + 1),
      avg_watch_time_seconds = CASE
        WHEN p_watch_time_seconds IS NOT NULL
        THEN (COALESCE(avg_watch_time_seconds, 0) * usage_count + p_watch_time_seconds)
             / (usage_count + 1)
        ELSE avg_watch_time_seconds
      END,
      confidence_score       = LEAST(
        (avg_engagement_rate * usage_count + p_engagement_rate) / (usage_count + 1) * 1000,
        100
      ),
      usage_count            = usage_count + 1,
      source_video_id        = CASE
        WHEN p_engagement_rate > avg_engagement_rate THEN p_source_video_id
        ELSE source_video_id
      END,
      updated_at             = NOW()
    WHERE client_id    = p_client_id
      AND element_type  = p_element_type
      AND element_value = p_element_value
    RETURNING id INTO v_memory_id;
  END IF;

  RETURN v_memory_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. ingest_video_kpis — point d'entrée unique pour le Learning Loop
--    Reçoit les KPIs bruts → log → extrait patterns → upsert mémoire
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ingest_video_kpis(
  p_video_id           UUID,
  p_platform           TEXT,
  p_views              BIGINT   DEFAULT 0,
  p_likes              BIGINT   DEFAULT 0,
  p_comments           BIGINT   DEFAULT 0,
  p_shares             BIGINT   DEFAULT 0,
  p_saves              BIGINT   DEFAULT 0,
  p_reach              BIGINT   DEFAULT 0,
  p_impressions        BIGINT   DEFAULT 0,
  p_watch_time_seconds NUMERIC  DEFAULT 0,
  p_avg_watch_pct      NUMERIC  DEFAULT NULL,
  p_raw_payload        JSONB    DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_client_id         UUID;
  v_script_json       JSONB;
  v_blotato_post_id   TEXT;
  v_kpi_id            UUID;
  v_engagement_rate   NUMERIC;
  v_memories_upserted INT := 0;
  v_hook              TEXT;
  v_cta               TEXT;
  v_format            TEXT;
  v_platform_norm     TEXT;
BEGIN
  SELECT client_id, script_json, blotato_post_id
  INTO v_client_id, v_script_json, v_blotato_post_id
  FROM video_production_notion
  WHERE id = p_video_id;

  IF v_client_id IS NULL THEN
    RAISE EXCEPTION 'Video not found: %', p_video_id;
  END IF;

  v_engagement_rate := CASE
    WHEN COALESCE(p_reach, p_views, 0) > 0
    THEN (p_likes + p_comments + p_shares + p_saves)::NUMERIC
         / NULLIF(COALESCE(p_reach, p_views), 0)
    ELSE 0
  END;

  -- Insert avec dédoublonnage par (video_id, platform, fetched_date)
  INSERT INTO video_kpi_log (
    video_id, client_id, platform, blotato_post_id,
    views, likes, comments, shares, saves, reach, impressions,
    watch_time_seconds, avg_watch_pct, raw_payload, fetched_date
  )
  VALUES (
    p_video_id, v_client_id, p_platform, v_blotato_post_id,
    p_views, p_likes, p_comments, p_shares, p_saves, p_reach, p_impressions,
    p_watch_time_seconds, p_avg_watch_pct, p_raw_payload, CURRENT_DATE
  )
  ON CONFLICT (video_id, platform, fetched_date) DO NOTHING
  RETURNING id INTO v_kpi_id;

  UPDATE video_production_notion
  SET updated_at = NOW()
  WHERE id = p_video_id;

  IF v_engagement_rate > 0 AND v_kpi_id IS NOT NULL THEN
    v_hook := COALESCE(v_script_json->>'hook', v_script_json->'script'->>'hook');
    IF v_hook IS NOT NULL AND LENGTH(TRIM(v_hook)) > 0 THEN
      PERFORM upsert_video_memory(v_client_id, p_video_id, 'hook', v_hook, v_engagement_rate, p_watch_time_seconds);
      v_memories_upserted := v_memories_upserted + 1;
    END IF;

    v_cta := COALESCE(v_script_json->>'cta', v_script_json->'script'->>'cta');
    IF v_cta IS NOT NULL AND LENGTH(TRIM(v_cta)) > 0 THEN
      PERFORM upsert_video_memory(v_client_id, p_video_id, 'cta', v_cta, v_engagement_rate, p_watch_time_seconds);
      v_memories_upserted := v_memories_upserted + 1;
    END IF;

    v_platform_norm := LOWER(COALESCE(p_platform, 'unknown'));
    PERFORM upsert_video_memory(v_client_id, p_video_id, 'platform_pattern', v_platform_norm, v_engagement_rate, p_watch_time_seconds);
    v_memories_upserted := v_memories_upserted + 1;

    v_format := v_script_json->'format_specs'->>'ratio';
    IF v_format IS NOT NULL THEN
      PERFORM upsert_video_memory(v_client_id, p_video_id, 'format', v_format, v_engagement_rate, NULL);
      v_memories_upserted := v_memories_upserted + 1;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'video_id',          p_video_id,
    'kpi_id',            v_kpi_id,
    'engagement_rate',   v_engagement_rate,
    'memories_upserted', v_memories_upserted,
    'skipped_duplicate', (v_kpi_id IS NULL)
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. learning_loop_candidates — vidéos published sans KPI récent
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW learning_loop_candidates AS
SELECT
  v.id                AS video_id,
  v.client_id,
  v.notion_page_id,
  v.title,
  v.platform,
  v.blotato_post_id,
  v.published_at,
  MAX(k.fetched_at)   AS last_kpi_fetch,
  EXTRACT(DAY FROM NOW() - v.published_at)::INT AS days_since_published
FROM video_production_notion v
LEFT JOIN video_kpi_log k ON k.video_id = v.id
WHERE v.statut         = 'published'
  AND v.blotato_post_id IS NOT NULL
  AND v.published_at    IS NOT NULL
  AND v.published_at BETWEEN NOW() - INTERVAL '90 days' AND NOW() - INTERVAL '1 day'
  AND NOT EXISTS (
    SELECT 1 FROM video_kpi_log k2
    WHERE k2.video_id    = v.id
      AND k2.fetched_date = CURRENT_DATE
  )
GROUP BY v.id, v.client_id, v.notion_page_id, v.title,
         v.platform, v.blotato_post_id, v.published_at;

-- ---------------------------------------------------------------------------
-- 5. memory_performance_summary — dashboard top patterns par client
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW memory_performance_summary AS
SELECT
  m.client_id,
  m.element_type,
  m.element_value,
  m.avg_engagement_rate,
  m.avg_watch_time_seconds,
  m.confidence_score,
  m.usage_count,
  RANK() OVER (
    PARTITION BY m.client_id, m.element_type
    ORDER BY m.avg_engagement_rate DESC NULLS LAST
  )                          AS rank_in_type,
  v.title                    AS best_source_video_title,
  v.platform                 AS best_source_platform
FROM video_memory_notion m
LEFT JOIN video_production_notion v ON v.id = m.source_video_id
WHERE m.is_active = TRUE;
