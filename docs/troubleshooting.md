# Troubleshooting Guide

## Top 10 Errors

### 1. Migration Fails on Fresh Supabase
**Symptom:** SQL error on migration 001+  
**Cause:** Extensions not enabled  
**Fix:** Run `migrations/000_extensions.sql` first

### 2. Webhook Not Received
**Symptom:** Notion event created but no pipeline trigger  
**Cause:** Webhook URL not configured in Notion, or workflow inactive  
**Fix:** 
1. Check n8n `Notion-Sync` workflow is **Active**
2. Verify webhook URL in Notion integration settings matches n8n trigger URL
3. Check n8n execution logs for the workflow

### 3. ComfyUI Timeout
**Symptom:** Image job stays in `processing` for 10+ minutes  
**Cause:** ComfyUI VPS unreachable or model not loaded  
**Fix:**
1. Check ComfyUI is running: `curl http://COMFYUI_BASE_URL/system_stats`
2. Verify `sdxl_base_1.0.safetensors` is in `models/checkpoints/`
3. Increase ComfyUI timeout in n8n workflow settings

### 4. fal.ai FAILED With No Message
**Symptom:** fal.ai job status = FAILED, no error message  
**Cause:** Invalid prompt or unsupported parameters  
**Fix:** Check raw fal.ai response in n8n execution log. Simplify the prompt.

### 5. Blotato Auth Error
**Symptom:** Publication fails with 401/403  
**Cause:** Expired or invalid BLOTATO_API_KEY  
**Fix:** Regenerate key in Blotato dashboard, update n8n env var

### 6. OpenRouter Rate Limit
**Symptom:** Script Agent returns 429 error  
**Cause:** Too many concurrent requests  
**Fix:** Add delay between Script Agent calls in n8n. Consider upgrading OpenRouter tier.

### 7. Processing Lock Not Released
**Symptom:** Video stuck in `processing`, lock exists past TTL  
**Fix:** See Operations Runbook — "Relaunching a Stuck Job"

### 8. Fal-Sweeper Not Triggering
**Symptom:** fal.ai jobs not picked up by sweeper  
**Cause:** Sweeper workflow not active or schedule misconfigured  
**Fix:** Verify Fal-Sweeper workflow is active with 15-min schedule in n8n

### 9. Learning Loop Has No Data
**Symptom:** `video_memory_notion` empty after runs  
**Cause:** No published videos with KPIs yet, or `platform` field mismatch  
**Fix:** Ensure at least one video has status `published` and KPI fields populated before running Learning Loop

### 10. n8n Workflow Shows Inactive
**Symptom:** Workflow exists but doesn't trigger  
**Fix:** Open the workflow in n8n UI and click **Activate** toggle. Check for missing credentials.
