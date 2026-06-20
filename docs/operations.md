# Operations Runbook

## Daily Health Check (30 seconds)

Run this query in Supabase SQL Editor:

```sql
SELECT statut, COUNT(*) as count, MAX(updated_at) as latest
FROM video_production_notion
GROUP BY statut
ORDER BY count DESC;
```

Expected: No videos stuck in intermediate states for more than 1 hour.

## Pipeline Health Views

```sql
-- Overall pipeline status
SELECT * FROM pipeline_health_summary;

-- Critical open alerts
SELECT * FROM critical_open_alerts;

-- Cost by video (last 7 days)
SELECT id, titre, cost_total_cad, statut, created_at
FROM video_production_notion
WHERE created_at > NOW() - INTERVAL '7 days'
ORDER BY cost_total_cad DESC;
```

## n8n Workflow Frequencies

| Workflow | Trigger | Frequency |
|----------|---------|-----------|
| Notion-Sync | Webhook | On Notion event |
| Script-Agent | Webhook | On queue entry |
| ComfyUI-Submit | Webhook | On script ready |
| ComfyUI-Poller | Schedule | Every 2 minutes |
| Fal-Submit | Webhook | On script ready |
| Fal-Webhook | Webhook | On fal.ai callback |
| Fal-Sweeper | Schedule | Every 15 minutes |
| Blotato-Publish | Webhook | On assets ready |
| Learning-Loop | Schedule | Every 24 hours |

## Relaunching a Stuck Job

If a video is stuck in `processing` state:

```sql
-- 1. Check the lock
SELECT * FROM processing_locks WHERE client_id = 'YOUR_CLIENT_ID';

-- 2. Release the lock manually if TTL has passed
DELETE FROM processing_locks 
WHERE client_id = 'YOUR_CLIENT_ID' 
AND lock_type = 'video_processing';

-- 3. Reset video status
UPDATE video_production_notion 
SET statut = 'pending' 
WHERE id = 'YOUR_VIDEO_ID';
```

## Dead-Letter Recovery

Videos in the `alert_queue` with `status = open`:

```sql
SELECT * FROM alert_queue WHERE status = 'open' ORDER BY created_at DESC;
```

Recovery steps:
1. Read the `message` field to understand the failure
2. Fix the root cause (missing asset, API failure, etc.)
3. Reset the video status to re-trigger the pipeline
4. Close the alert: `UPDATE alert_queue SET status = 'resolved' WHERE id = 'ALERT_ID';`

## Budget Alerts

If cost alerts are firing:
```sql
SELECT client_id, SUM(cost_total_cad) as total_cost
FROM video_production_notion
WHERE created_at > date_trunc('month', NOW())
GROUP BY client_id
ORDER BY total_cost DESC;
```

Adjust per-client budget thresholds in the `clients` table.
