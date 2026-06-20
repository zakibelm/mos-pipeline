# End-to-End Test Plan

## Goal
Generate, process, publish, and ingest KPIs for one test video — validating the full pipeline from Notion to Learning Loop.

## Preconditions
- [ ] All 7 migrations applied successfully
- [ ] All 9 n8n workflows imported and **Active**
- [ ] All env vars configured and valid
- [ ] ComfyUI reachable and SDXL model loaded
- [ ] fal.ai API key valid
- [ ] Supabase Storage bucket `mos-images` exists (public)
- [ ] Blotato sandbox or test account ready

## Test Data
```
Client:   Test Client
Title:    Test MOS Pipeline
Platform: instagram_reels
Language: fr-CA
Topic:    Productivité et IA
Tone:     Inspirant
```

## Expected Flow

| Step | Action | Expected Result | Validation Query |
|------|--------|----------------|-----------------|
| 1 | Create Notion entry | Notion-Sync triggers | `SELECT statut FROM video_production_notion ORDER BY created_at DESC LIMIT 1;` → `pending` |
| 2 | Script Agent runs | script_json populated | `SELECT script_json IS NOT NULL FROM video_production_notion ORDER BY created_at DESC LIMIT 1;` → `true` |
| 3 | ComfyUI job created | image_generation_queue entry | `SELECT COUNT(*) FROM image_generation_queue WHERE status = 'completed';` → `≥ 1` |
| 4 | Image generated | reference_image_url populated | `SELECT reference_image_url FROM video_production_notion ORDER BY created_at DESC LIMIT 1;` → non-null |
| 5 | fal.ai job created | fal_video_queue entry | `SELECT COUNT(*) FROM fal_video_queue WHERE status = 'completed';` → `≥ 1` |
| 6 | Video generated | video_url populated | `SELECT video_url FROM video_production_notion ORDER BY created_at DESC LIMIT 1;` → non-null |
| 7 | Blotato publishes | statut = published | `SELECT statut FROM video_production_notion ORDER BY created_at DESC LIMIT 1;` → `published` |
| 8 | KPIs ingested (48h) | Learning Loop runs | `SELECT COUNT(*) FROM video_memory_notion;` → `≥ 1` |

## Failure Path Tests (Sprint 9.5+)

- [ ] Simulate ComfyUI unreachable → verify alert_queue entry created
- [ ] Drop fal.ai webhook → verify Sweeper picks up after 15 min
- [ ] Simulate Blotato 401 → verify retry 3x then dead-letter
- [ ] Simulate OpenRouter 429 → verify fallback or graceful failure

## Post-Test Validation

```sql
-- Full video state
SELECT id, titre, statut, script_json IS NOT NULL as has_script,
       reference_image_url IS NOT NULL as has_image,
       video_url IS NOT NULL as has_video,
       cost_total_cad, created_at
FROM video_production_notion
ORDER BY created_at DESC LIMIT 1;

-- No open critical alerts
SELECT COUNT(*) as open_alerts FROM alert_queue WHERE status = 'open';

-- Learning memory populated
SELECT COUNT(*) as memory_patterns FROM video_memory_notion;
```
