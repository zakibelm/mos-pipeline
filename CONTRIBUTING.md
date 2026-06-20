# Contributing to MOS Pipeline

## Anti-Regression Checklist

Before opening a PR, verify:

- [ ] Any new environment variable is added to `.env.example` with a comment
- [ ] Any new n8n workflow has a contract documented in `docs/contracts/`
- [ ] Any new migration has been tested on an empty Supabase project before merge
- [ ] `gitleaks` scan passes (no secrets committed)
- [ ] All JSON files in `n8n/` and `comfyui/` are valid (run `jq empty` on each)
- [ ] CI passes on your branch before requesting review

## Commit Message Convention

Use conventional commits:

```
feat:    New feature or workflow
fix:     Bug fix (including SQL corrections)
docs:    Documentation changes
chore:   Tooling, scripts, CI
ci:      GitHub Actions changes
refactor: Code refactoring without behavior change
```

## Adding a New Migration

1. Create `migrations/00X_description.sql`
2. Test it on a fresh Supabase project (empty DB)
3. Add a corresponding `migrations/rollbacks/00X_rollback.sql`
4. Update `migrations/validate/smoke-test.sql` if new tables/functions are added
5. Run `scripts/smoke-test.sh` to validate

## Adding a New n8n Workflow

1. Export the workflow as JSON to `n8n/MOS-vX.Y-Name.json`
2. Ensure no hardcoded credentials or URLs (use env vars)
3. Create `docs/contracts/service-name.md` if integrating a new external service
4. Document the workflow in `docs/operations.md`

## Security Rules

- Never commit `.env` or any file containing real API keys
- Never include VPS hostnames, IP addresses, or project IDs in documentation
- Always use `MOS_WEBHOOK_SECRET` on internal webhook endpoints
- Rotate API keys after staging/prod handoff
