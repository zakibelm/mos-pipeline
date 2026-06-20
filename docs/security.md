# Security Guide

## Core Rules

1. **Never commit `.env`** — Use `.gitignore` (already configured)
2. **Service Role Key** — Use only in server-side environments (n8n, backend). Never expose client-side.
3. **Webhook Authentication** — Always validate `MOS_WEBHOOK_SECRET` on internal webhook calls
4. **Key Rotation** — Rotate all API keys after staging → production handoff
5. **RLS** — Enable Row Level Security on all Supabase tables before production
6. **No infra in docs** — Never include VPS hostnames, IP addresses, Supabase project IDs, or real credentials in documentation or code

## Secrets Scanning

This repo uses [gitleaks](https://github.com/gitleaks/gitleaks) in CI to scan for accidentally committed secrets.

Run locally before pushing:
```bash
docker run -v ${PWD}:/path zricethezav/gitleaks:latest detect --source="/path" --verbose
```

## Supabase RLS (Pre-Production Checklist)

Enable RLS on these tables before going to production:
- `clients`
- `video_production_notion`
- `image_generation_queue`
- `fal_video_queue`
- `video_memory_notion`
- `alert_queue`

```sql
ALTER TABLE clients ENABLE ROW LEVEL SECURITY;
ALTER TABLE video_production_notion ENABLE ROW LEVEL SECURITY;
-- ... repeat for each table
```

## Staging vs Production

- Use **separate Supabase projects** for staging and production
- Use **different API keys** for each environment
- Never use production Blotato credentials in staging
- Tag all staging videos with a prefix to avoid accidental publishing

## Incident Response

If you suspect a secret has been committed:
1. Immediately rotate the affected key
2. Remove from git history using `git filter-branch` or BFG Repo Cleaner
3. Force push (coordinate with team)
4. Notify affected service providers if needed
