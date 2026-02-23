# 03 — Device/Model Viability Matrix (initial)

> Note: these are directional values for test planning and should be refined with real benchmarks.

## Suggested Profiles

### iPad M1
- Recommended local profile: quantized 3B–7B.
- Ideal usage: general chat, short summaries, drafting.
- Risk: thermal throttling during long sessions.

### iPad M2
- Recommended local profile: stable quantized 7B; 8B depending on runtime.
- Ideal usage: general chat + moderate reasoning.
- Risk: battery draw under sustained load.

### iPad M4
- Recommended local profile: more comfortable 7B–8B, better latency.
- Ideal usage: longer local sessions.
- Risk: still limited for complex full-agent workflows.

## Routing Rules (proposal)
- Local if: short/medium prompt + no heavy tool use.
- Delegated if: long context, multi-step tasks, or external tool needs.

## Prototype Metrics to Measure
1. Time-to-first-token.
2. Sustained tokens/sec.
3. Peak memory usage.
4. Battery drop over 15 minutes.
5. Perceived temperature and overall stability.
