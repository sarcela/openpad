# Local Model Setup (iPad)

Este setup deja el proyecto listo para correr local con un `.gguf`.

## 1) Integrar backend llama.cpp en Xcode

1. Abre tu proyecto en Xcode.
2. Ve a **File > Add Package Dependencies...**
3. Agrega el paquete de llama.cpp Swift que vayas a usar.
4. Asigna el package a tu target `OpenClawPad`.

> Nota: el scaffold actual usa `#if canImport(LlamaCpp)`.
> Si tu package expone otro módulo, ajusta ese nombre en `LlamaLocalModelService.swift`.

---

## 2) Copiar modelo al iPad

Rutas reconocidas por defecto (en este orden):

1. `Files > On My iPad > OpenClawPad > Models > Qwen2.5-0.5B-Instruct-Q4_K_M.gguf`
2. `Files > On My iPad > OpenClawPad > Models > model.gguf`

Pasos:
1. En iPad abre app **Files**.
2. Ve a **On My iPad**.
3. Entra a carpeta de tu app (`OpenClawPad`).
4. Crea carpeta `Models` si no existe.
5. Copia tu archivo `.gguf` (recomendado: `Qwen2.5-0.5B-Instruct-Q4_K_M.gguf`).

---

## 3) Archivos ya preparados

- `Services/LocalModelService.swift` → intenta cargar automáticamente `Models/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf` y luego `Models/model.gguf`.
- `Services/LlamaLocalModelService.swift` → punto de integración llama real.
- `Services/LocalModelConfig.swift` → nombre/ruta de modelo por defecto.

---

## 4) Qué falta para inferencia real

En `LlamaLocalModelService.swift`, dentro de:

```swift
#if canImport(LlamaCpp)
// TODO: Conectar aquí la API real
#endif
```

reemplaza el stub por:
- carga de modelo GGUF,
- creación de contexto,
- inferencia con prompt,
- retorno de texto generado.

---

## 5) Verificación rápida

1. Corre app en iPad.
2. Envía un prompt corto.
3. Si no encuentra modelo: verás mensaje con tip de ruta.
4. Si encuentra modelo + backend integrado: debe responder local.

---

## 6) Recomendación inicial de modelo

- Tamaño: 3B a 8B
- Quant: Q4_K_M (balance velocidad/calidad)
- Contexto inicial: 8k–12k

