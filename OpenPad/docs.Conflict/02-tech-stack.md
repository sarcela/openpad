# 02 — Stack Técnico Propuesto

## App
- **UI:** SwiftUI
- **Plataforma:** iPadOS (M1/M2/M4)
- **Persistencia local:** SQLite o SwiftData (historial + settings)

## Inference local (candidatos)
1. **MLX (preferido para ecosistema Apple Silicon)**
   - Pros: buen rendimiento en Apple Silicon, comunidad creciendo.
   - Contras: integración iPad específica a validar.
2. **MLC / runtime compatible iOS/iPadOS**
   - Pros: enfoque mobile deployment.
   - Contras: complejidad de pipeline/model conversion.
3. **Core ML (modelos convertidos)**
   - Pros: integración nativa Apple.
   - Contras: conversión y soporte de modelos LLM variable.

## Estrategia recomendada
- Empezar con runtime que tenga mejor camino de integración real en iPad hoy.
- Mantener capa de abstracción `InferenceEngine` para poder cambiar runtime sin reescribir UI.

## Arquitectura (alto nivel)
- `ChatUI` (SwiftUI)
- `ConversationStore` (historial local)
- `InferenceEngine` (local)
- `DelegateClient` (handoff a Mac/servidor)
- `PolicyRouter` (decide local vs delegado según contexto y tamaño de tarea)
