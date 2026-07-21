# MLXExample

MLXExample combines a native SwiftUI iOS frontend with an on-device MLX
inference backend. It runs Qwen3 locally through
[MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm), without an API
server. The backend downloads a four-bit MLX model, caches it on the device,
and exposes model operations to the frontend.

## Features

- Native SwiftUI chat interface
- On-device inference using Apple MLX
- Model download and extraction progress
- Persistent model cache in the app's Application Support directory
- Multi-turn chat with selectable responses
- iPhone and iPad support

After the initial model download, prompts and responses are processed locally.

## Architecture

The project has two primary layers:

- **iOS frontend (`ios/QtLlamaSwiftUI`)** — the SwiftUI interface, chat state,
  model status, download progress, and user interaction.
- **MLX backend (`ios/MLXQtBridge`)** — a local Swift package responsible for
  downloading and extracting the model, loading it with MLX Swift LM, managing
  the chat session, and generating responses.

```text
SwiftUI views
    │
    ▼
ChatViewModel
    │
    ▼
MLXQtBridge / ModelManager
    │
    ├── downloads and caches the MLX model
    └── runs Qwen3 inference with MLX Swift LM
```

The bridge provides a native Swift `ModelManager` API used by the current
frontend. It also exports C-compatible lifecycle, model-loading, generation,
download, and cancellation functions for integration with other native UI
layers.

## Requirements

- An Apple-silicon Mac
- Xcode with Swift 6 support
- XcodeGen only when regenerating the checked-in Xcode project
- iOS 17 or later
- A physical iPhone or iPad recommended for inference
- An Apple development team for installing on a device
- Approximately 2.1 GB for the model download, plus space for extraction and
  runtime data

A recent device with at least 6 GB of memory is recommended for the four-bit
4B model. The simulator is useful for UI work, but a physical Apple-silicon
device is the intended inference target.

## Project structure

```text
.
├── backend/
│   ├── convert_to_mlx.py          Optional Hugging Face-to-MLX converter
│   ├── requirements-mlx-convert.txt
│   └── Qwen3-4B-Q4_K_M.gguf       GGUF model; not loaded by the iOS app
└── ios/
    ├── Assets.xcassets/            Shared app assets
    ├── MLXQtBridge/                On-device MLX inference backend
    ├── PrivacyInfo.xcprivacy       App privacy manifest
    └── QtLlamaSwiftUI/             iOS frontend and Xcode project
```

The top-level `backend` directory contains development-time model tooling and
a GGUF artifact. Runtime inference for the iOS app is implemented by
`ios/MLXQtBridge`; the app does not run a separate Python service.

## Build and run

1. Open `ios/QtLlamaSwiftUI/QtLlamaSwiftUI.xcodeproj` in Xcode.
2. Select the `QtLlamaSwiftUI` target.
3. Under **Signing & Capabilities**, choose your development team and change
   the bundle identifier if needed.
4. Select an iPhone or iPad running iOS 17 or later.
5. Build and run the `QtLlamaSwiftUI` scheme.

The project uses `ios/MLXQtBridge` as a local Swift package. Xcode resolves its
pinned package dependencies the first time the project is opened.

To verify a simulator build from the repository root:

```sh
xcodebuild \
  -project ios/QtLlamaSwiftUI/QtLlamaSwiftUI.xcodeproj \
  -scheme QtLlamaSwiftUI \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### Regenerate the Xcode project

The checked-in project is generated from `ios/QtLlamaSwiftUI/project.yml`.
After changing that definition, install
[XcodeGen](https://github.com/yonaskolb/XcodeGen) and run:

```sh
cd ios/QtLlamaSwiftUI
xcodegen generate
```

## Download and use the model

1. Launch the app and tap **Download model**.
2. Keep the app in the foreground while the archive downloads and extracts.
3. Wait for the status to change to **Model ready**.
4. Enter a prompt and tap **Send**.

The app downloads `Qwen3-4B-4bit-mlx`, extracts it into
`Application Support/Models`, and reuses it on subsequent launches. Generation
currently uses a 512-token maximum response length, a 2,048-token rotating KV
cache, and a temperature of 0.7. Deleting the app or its data removes the
cached model.

## Optional model conversion

The Python utility converts original Hugging Face-format weights to an MLX
model directory on Apple silicon. It cannot convert GGUF directly because GGUF
and MLX use different formats and quantization layouts.

```sh
cd backend
python3 -m venv .venv-mlx
source .venv-mlx/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements-mlx-convert.txt
python convert_to_mlx.py
```

Run `python convert_to_mlx.py --help` for source model, revision, output,
quantization, and Hugging Face upload options. Creating a local conversion does
not change the download URL used by the app; that URL is configured in
`ios/MLXQtBridge/Sources/MLXQtBridge/MLXQtBridge.swift`.

## Troubleshooting

### The message field is disabled

The composer becomes available only after the model is downloaded and loaded.
If the download fails, check the displayed error, network connection, and free
storage, then relaunch and retry.

### The app exits while loading or generating

A four-bit 4B model still needs several gigabytes of memory. Close other
memory-intensive apps or use a newer device with more RAM.

### Xcode shows keyboard constraint warnings

Warnings mentioning `com.google.keyboard.KeyboardExtension`,
`_UIKBCompatInputView`, or `TUIKeyboardContentView` can originate from a
third-party keyboard extension. Retest with Apple's system keyboard.

### Metal shows unused-variable warnings

Warnings from `mlx/backend/metal/kernels` can appear while MLX compiles its
Metal kernels. They are non-fatal when compilation succeeds.

## Privacy

Prompts and responses remain on the device after the model is installed. A
network connection is required for the initial model and Swift package
downloads. Review `ios/PrivacyInfo.xcprivacy` and all linked SDK declarations
before distributing the app.
