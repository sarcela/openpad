# 02 — Proposed Technical Stack

## App
- **UI:** SwiftUI
- **Platform:** iPadOS (M1/M2/M4)
- **Local persistence:** SQLite or SwiftData (history + settings)

## Local Inference (candidates)
1. **MLX (preferred for Apple Silicon ecosystem)**
   - Pros: strong Apple Silicon performance, growing community.
   - Cons: iPad-specific integration still needs validation.
2. **MLC / iOS-iPadOS compatible runtime**
   - Pros: mobile deployment focus.
   - Cons: model conversion/pipeline complexity.
3. **Core ML (converted models)**
   - Pros: native Apple integration.
   - Cons: variable conversion and support across LLM families.

## Recommended Strategy
- Start with the runtime that has the most practical integration path on iPad today.
- Keep an `InferenceEngine` abstraction layer so runtimes can be swapped without rewriting UI.

## High-Level Architecture
- `ChatUI` (SwiftUI)
- `ConversationStore` (local history)
- `InferenceEngine` (local)
- `DelegateClient` (handoff to Mac/server)
- `PolicyRouter` (decides local vs delegated based on context/task size)
