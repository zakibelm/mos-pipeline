-- =============================================================================
-- MOS v5.0 — Migration 000: PostgreSQL Extensions
-- Run this FIRST before any other migration
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Verify extensions are enabled
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'uuid-ossp') THEN
    RAISE EXCEPTION 'uuid-ossp extension failed to install';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgcrypto') THEN
    RAISE EXCEPTION 'pgcrypto extension failed to install';
  END IF;
  RAISE NOTICE 'Extensions verified: uuid-ossp, pgcrypto';
END $$;
