# MOS Pipeline

![Validate](https://github.com/zakibelm/mos-pipeline/actions/workflows/validate.yml/badge.svg)

Media Operations System for AI-assisted short-form video production.

## What It Does

MOS orchestrates a fully automated video pipeline across Notion, Supabase, n8n, OpenRouter, ComfyUI, fal.ai, Blotato, and a KPI learning loop — from content brief to published video.

## I am...

| Profile | Starting point |
|---------|---------------|
| 🟢 **Novice** — I want results, not setup | `docs/setup.md` → Quick Start in 30 min |
| 🟡 **Standard** — I know n8n and want to customise | `docs/architecture.md` → then `docs/operations.md` |
| 🔴 **Expert** — I want to extend or audit the system | `CONTRIBUTING.md` → `docs/security.md` → migrations/ |

## Quick Start

1. Copy `.env.example` to `.env` and fill in your credentials
2. Configure Supabase, Notion, OpenRouter, ComfyUI, fal.ai, and Blotato
3. Run migrations:
   - Linux/macOS/CI: `./scripts/migrate.sh`
   - Windows: `./scripts/migrate.ps1`
4. Run smoke test:
   - Linux/macOS: `./scripts/smoke-test.sh`
   - SQL only: `migrations/validate/smoke-test.sql`
5. Import n8n workflows from `n8n/`
6. Follow the E2E scenario in `docs/e2e-test-plan.md`
7. Ship your first video

## Documentation

| Document | Purpose |
|----------|---------|
| [Setup](docs/setup.md) | Fresh install guide |
| [Architecture](docs/architecture.md) | System design and data flow |
| [Operations](docs/operations.md) | Day-to-day runbooks |
| [Troubleshooting](docs/troubleshooting.md) | Common failures and fixes |
| [Security](docs/security.md) | Secrets management and access control |
| [E2E Test Plan](docs/e2e-test-plan.md) | Manual validation scenario |
| [Contributing](CONTRIBUTING.md) | Anti-regression rules and PR checklist |

## Pipeline Overview

```
Notion brief → n8n trigger → OpenRouter (script) → ComfyUI (images) → fal.ai (video) → Blotato (publish) → KPI loop
                                    ↓
                              Supabase (state, queue, metrics)
```

## Status

- **Sprint 9.0 complete** — installable, documented, CI-validated, smoke-testable
- **Sprint 9.5+ next** — integration contracts, failure injection, cost alerts, automated E2E
