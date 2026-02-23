# Local Model Setup (iPad)

This setup gets the project ready to run locally with a `.gguf` model.

## 1) Integrate a llama.cpp backend in Xcode

1. Open your project in Xcode.
2. Go to **File > Add Package Dependencies...**
3. Add the Swift llama.cpp package you want to use.
4. Assign the package to your `OpenClawPad` target.

> Note: the current scaffold uses `#if canImport(LlamaCpp)`.
> If your package exposes a different module name, update it in `LlamaLocalModelService.swift`.

---

## 2) Copy the model to iPad

Default recognized paths (in this order):

1. `Files > On My iPad > OpenClawPad > Models > Qwen2.5-0.5B-Instruct-Q4_K_M.gguf`
2. `Files > On My iPad > OpenClawPad > Models > model.gguf`

Steps:
1. Open the **Files** app on iPad.
2. Go to **On My iPad**.
3. Open your app folder (`OpenClawPad`).
4. Create a `Models` folder if it does not exist.
5. Copy your `.gguf` file (recommended: `Qwen2.5-0.5B-Instruct-Q4_K_M.gguf`).

---

## 3) Files already prepared

- `Services/LocalModelService.swift` → tries to auto-load `Models/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf` and then `Models/model.gguf`.
- `Services/LlamaLocalModelService.swift` → real llama integration entry point.
- `Services/LocalModelConfig.swift` → default model name/path handling.

---

## 4) What is still needed for real inference

In `LlamaLocalModelService.swift`, inside:

```swift
#if canImport(LlamaCpp)
// TODO: connect real API here
#endif
```

replace the stub with:
- GGUF model loading,
- context creation,
- prompt inference,
- generated text return.

---

## 5) Quick verification

1. Run the app on iPad.
2. Send a short prompt.
3. If model is missing: you should see a path hint message.
4. If model exists + backend is integrated: it should answer locally.

---

## 6) Initial model recommendation

- Size: 3B to 8B
- Quant: Q4_K_M (speed/quality balance)
- Initial context: 8k–12k
