# OpenClawPad – Start Here

## Archivos clave

- `OpenClawPadApp.swift`
- `Views/ChatView.swift`
- `ViewModels/ChatViewModel.swift`
- `Services/RoutingService.swift`
- `Services/LocalModelService.swift`
- `Services/LlamaLocalModelService.swift`
- `Services/RemoteModelService.swift`
- `Services/RemoteModelConfig.swift`
- `Docs/LOCAL_MODEL_SETUP.md`
- `Design/logo-openclawpad.svg`

## Estado actual

- UI de chat funcional.
- Selector de modo en UI: **AUTO / LOCAL / REMOTE** (persistente).
- Fallback básico activo: si LOCAL falla/timeout, intenta REMOTE automáticamente.
- Config remoto editable desde UI (botón de nube): Base URL + Token + Model.
- Carga automática de modelo local esperada en:
  - `Files > On My iPad > OpenClawPad > Models > Qwen2.5-0.5B-Instruct-Q4_K_M.gguf`
  - fallback: `Files > On My iPad > OpenClawPad > Models > model.gguf`
- App icon listo en `Assets.xcassets/AppIcon.appiconset/` (iPad + marketing).
- Backend de inferencia llama.swift: **scaffold listo** (falta conectar API exacta del package que elijas).

## Próximo paso

Sigue `Docs/LOCAL_MODEL_SETUP.md` para conectar el package llama y activar inferencia real.

## Smoke test rápido (MVP híbrido)

- Prompt corto sin tools: debe responder por ruta local (<8s objetivo).
- Prompt largo o con tools externas: debe hacer handoff remoto automáticamente.
- Si falla local (timeout/error): fallback remoto sin perder el mensaje.
- En modo avión: mantener flujo local y mostrar aviso de modo offline.
