#!/bin/bash
# MOS v5.0 — Database Migration Script
# Platform: Linux / macOS / CI (GitHub Actions)
# For Windows, use scripts/migrate.ps1

set -e

if [ -f ".env" ]; then
  export $(grep -v '^#' .env | xargs)
fi

if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_SERVICE_KEY" ]; then
  echo "ERROR: SUPABASE_URL and SUPABASE_SERVICE_KEY must be set"
  exit 1
fi

PROJECT_ID=$(echo $SUPABASE_URL | sed 's|https://||' | sed 's|.supabase.co||')
DB_HOST="db.${PROJECT_ID}.supabase.co"
DB_URL="postgresql://postgres:${SUPABASE_SERVICE_KEY}@${DB_HOST}:5432/postgres"

echo "Starting MOS migrations... Project: ${PROJECT_ID}"

MIGRATIONS=(
  "migrations/000_extensions.sql"
  "migrations/001_v4_1_sprint1_base.sql"
  "migrations/002_v4_1_sprint2_rag.sql"
  "migrations/003_v4_1_sprint3_comfyui.sql"
  "migrations/004_v4_1_sprint4_fal.sql"
  "migrations/005_v4_1_sprint5_blotato.sql"
  "migrations/006_v4_1_sprint6_learning_loop.sql"
)

for migration in "${MIGRATIONS[@]}"; do
  if [ -f "$migration" ]; then
    echo "  Applying $migration..."
    psql "$DB_URL" -f "$migration" -q
    echo "  OK: $migration"
  else
    echo "  ERROR: $migration not found"; exit 1
  fi
done

echo "All migrations applied. Run ./scripts/smoke-test.sh to validate."
