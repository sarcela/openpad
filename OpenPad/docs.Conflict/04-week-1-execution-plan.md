# 04 — Execution Plan (Week 1)

Week goal: reach a functional iPad app prototype with basic chat, minimal local path (mock or real), and defined delegated path.

## Day 1 — Project baseline setup
**Deliverables**
- iPad project (SwiftUI) created.
- Initial module structure (`ChatUI`, `ConversationStore`, `InferenceEngine`, `DelegateClient`, `PolicyRouter`).
- Short document with initial technical decisions.

**Checklist**
- [ ] Create base repo/app
- [ ] Configure targets and build settings
- [ ] Define interfaces/protocols

---

## Day 2 — Chat UI + local state
**Deliverables**
- Functional chat screen (input, message list, loading states).
- Minimal local persistence for recent conversations.

**Checklist**
- [ ] Chat view with simulated streaming
- [ ] Local history save/load
- [ ] Basic UX error handling

---

## Day 3 — Local engine (PoC)
**Deliverables**
- Initial local runtime integration (PoC) or realistic mock.
- First end-to-end local response.

**Checklist**
- [ ] Implement `InferenceEngine` v0
- [ ] Load a small model or equivalent mock
- [ ] Measure first-response latency

---

## Day 4 — Delegated path (handoff)
**Deliverables**
- `DelegateClient` with configurable endpoint.
- Button/selector to force delegated responses.

**Checklist**
- [ ] Secure connection to backend/Mac
- [ ] Clear UX for "Local" vs "Delegated"
- [ ] Basic retry + timeout

---

## Day 5 — Policy router
**Deliverables**
- Basic automatic rules for local vs delegated routing.
- Decision logs for debugging.

**Checklist**
- [ ] Heuristics by prompt/context size
- [ ] Automatic fallback to delegated on local error
- [ ] Basic per-route metrics

---

## Day 6 — On-device measurement (M1/M2/M4)
**Deliverables**
- Mini internal benchmark (TTFT, fluency, stability).
- Initial parameter tuning per iPad profile.

**Checklist**
- [ ] 10–15 minute test per route
- [ ] Battery/temperature observation
- [ ] Tune limits to reduce throttling

---

## Day 7 — Sprint close + backlog
**Deliverables**
- Working internal demo.
- Prioritized list for Week 2.
- Decision on final runtime candidate for v1.

**Checklist**
- [ ] Demo script (3 scenarios)
- [ ] Open risks documented
- [ ] Next steps approved

---

## Definition of "done" for Week 1
1. App opens and maintains local conversations.
2. App can answer via both local route (even if limited) and delegated route.
3. There is a basic automatic routing criterion.
4. First real metrics exist on at least one M-series iPad.
