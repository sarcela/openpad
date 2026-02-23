# 01 — MVP Scope (iPad M1/M2/M4)

## MVP Goal
Deliver a functional iPad app for assisted chat, with local inference for fast tasks and fallback/handoff for heavier tasks.

## Includes (v1)
1. Local chat (on-device history).
2. Quantized local model (3B–8B depending on device).
3. Response modes (fast/balanced).
4. Short local memory (current session + recent conversations).
5. Simple local attachments (text, static images for basic context).
6. Hybrid mode: button to delegate heavy responses to backend/Mac.

## Excludes (v1)
1. Full OpenClaw tools ecosystem execution on iPad.
2. Long-running background automation (iPadOS limitations).
3. Persistent local multi-agent orchestration.
4. On-device local fine-tuning.

## Success Criteria
- Acceptable time-to-first-token for casual chat.
- Stable UX without memory-related crashes.
- Explicit switching between "local" and "delegated".
- Battery/temperature within reasonable ranges during 10–20 minute sessions.
