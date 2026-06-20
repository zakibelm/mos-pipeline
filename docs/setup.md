# Setup Guide

## Prerequisites

- Supabase account (free tier works for staging)
- n8n instance (self-hosted or n8n.cloud)
- OpenRouter account with API key
- ComfyUI instance (GPU VPS or local)
- fal.ai account
- Blotato account
- Notion workspace with integration enabled

**Note:** Scripts in `scripts/` are for Linux/macOS/CI environments.
Windows users: use `scripts/migrate.ps1` or run SQL files manually in Supabase SQL Editor.

## Step 1 — Clone and Configure

```bash
git clone https://github.com/zakibelm/mos-pipeline.git
cd mos-pipeline
cp .env.example .env
# Edit .env with your actual values
```

## Step 2 — Initialize Supabase

1. Create a new Supabase project at [supabase.com](https://supabase.com)
2. Go to **Settings > API** and copy your Project URL and Service Role Key into `.env`
3. Run migrations:

```bash
./scripts/migrate.sh
# Or on Windows:
# ./scripts/migrate.ps1
```

Or run manually in Supabase SQL Editor in order:
- `migrations/000_extensions.sql`
- `migrations/001_v4_1_sprint1_base.sql`
- `migrations/002_v4_1_sprint2_rag.sql`
- `migrations/003_v4_1_sprint3_comfyui.sql`
- `migrations/004_v4_1_sprint4_fal.sql`
- `migrations/005_v4_1_sprint5_blotato.sql`
- `migrations/006_v4_1_sprint6_learning_loop.sql`

## Step 3 — Create Storage Bucket

In Supabase Dashboard > Storage:
1. Create a new bucket named `mos-images`
2. Set it to **Public** (for image serving)

## Step 4 — Import n8n Workflows

In your n8n instance:
1. Go to **Workflows > Import**
2. Import each file from `n8n/` in this order:
   - `MOS-v4.1-Notion-Sync.json`
   - `MOS-v4.1-Script-Agent.json`
   - `MOS-v4.1-ComfyUI-Submit.json`
   - `MOS-v4.1-ComfyUI-Poller.json`
   - `MOS-v4.1-Fal-Submit.json`
   - `MOS-v4.1-Fal-Webhook.json`
   - `MOS-v4.1-Fal-Sweeper.json`
   - `MOS-v4.1-Blotato-Publish.json`
   - `MOS-v4.1-Learning-Loop.json`

## Step 5 — Configure Environment Variables in n8n

Add all variables from `.env.example` as **n8n credentials** or environment variables on your n8n instance.

## Step 6 — Activate Webhooks

1. Activate the **Notion-Sync** workflow first
2. Copy the webhook URL from the trigger node
3. Add it to your Notion integration settings
4. Activate all other workflows

## Step 7 — Run Smoke Test

```bash
./scripts/smoke-test.sh
```

Expected output: `✓ All 8 tables present. Pipeline ready.`

## Step 8 — Create Your First Video

1. Open your Notion database
2. Create a new video entry with: Topic, Platform, Tone
3. The pipeline will trigger automatically
4. Check the `video_production_notion` table for status updates
