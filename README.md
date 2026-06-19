# MOS v4.1-RC1 Pipeline

Media Operations System - Video Pipeline Architecture

## Sprints
- Sprint 1: Base DB (8 tables, 3 views, 9 functions)
- Sprint 2: Script Agent (RAG, OpenRouter, memory)
- Sprint 3: ComfyUI (Lock VPS, Poller, Storage)
- Sprint 4: fal.ai (Webhook + Sweeper + dead letter)
- Sprint 5: Blotato (Publication + planning)
- Sprint 6: Learning Loop (KPI → video_memory_notion)

## Infrastructure
- VPS: srv679767.hstgr.cloud (Ubuntu 24.04, KVM 8)
- Supabase: mos-pipeline-ia (ca-central-1)
- n8n workflows for automation
