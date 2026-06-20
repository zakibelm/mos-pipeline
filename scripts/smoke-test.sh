#!/bin/bash
# MOS v5.0 — Smoke Test: validates DB schema

set -e

if [ -f ".env" ]; then
  export $(grep -v '^#' .env | xargs)
fi

if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_SERVICE_KEY" ]; then
  echo "ERROR: SUPABASE_URL and SUPABASE_SERVICE_KEY must be set"; exit 1
fi

PROJECT_ID=$(echo $SUPABASE_URL | sed 's|https://||' | sed 's|.supabase.co||')
DB_URL="postgresql://postgres:${SUPABASE_SERVICE_KEY}@db.${PROJECT_ID}.supabase.co:5432/postgres"

echo "Running MOS smoke test..."

RESULT=$(psql "$DB_URL" -t -c "
  SELECT COUNT(*) FROM information_schema.tables
  WHERE table_schema = 'public'
  AND table_name IN (
    'clients', 'video_production_notion', 'image_generation_queue',
    'fal_video_queue', 'video_memory_notion', 'processing_locks',
    'alert_queue', 'notion_sync_events'
  );
" 2>/dev/null | tr -d ' ')

if [ "$RESULT" = "8" ]; then
  echo "All 8 tables present. Pipeline ready."
  exit 0
else
  echo "Expected 8 tables, found $RESULT. Check migrations."
  exit 1
fi
