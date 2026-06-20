-- =============================================================================
-- MOS v5.0 — Smoke Test
-- Validates that all expected tables, views, and functions exist
-- Expected result: tables_count = 8, views_count = 3, functions_count >= 5
-- =============================================================================

-- Check tables
SELECT 'TABLES' as check_type,
       COUNT(*) as found,
       8 as expected,
       CASE WHEN COUNT(*) = 8 THEN 'PASS' ELSE 'FAIL' END as result
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN (
    'clients',
    'video_production_notion',
    'image_generation_queue',
    'fal_video_queue',
    'video_memory_notion',
    'processing_locks',
    'alert_queue',
    'notion_sync_events'
  );

-- Check views
SELECT 'VIEWS' as check_type,
       COUNT(*) as found,
       3 as expected,
       CASE WHEN COUNT(*) >= 3 THEN 'PASS' ELSE 'FAIL' END as result
FROM information_schema.views
WHERE table_schema = 'public';

-- Check key functions
SELECT 'FUNCTIONS' as check_type,
       COUNT(*) as found,
       5 as expected,
       CASE WHEN COUNT(*) >= 5 THEN 'PASS' ELSE 'FAIL' END as result
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN (
    'acquire_processing_lock',
    'release_processing_lock',
    'upsert_video_memory',
    'ingest_video_kpis',
    'create_alert'
  );
