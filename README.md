# MLXExample

Native Qwen3 chat for iPhone and iPad, powered by Apple MLX.

MLXExample combines a SwiftUI interface with an on-device inference layer. It
runs Qwen3 locally through
[MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm), without an API
server. After a model archive URL is configured, the app downloads a four-bit
MLX model, caches it on the device, and processes conversations locally.

## Features

- Native SwiftUI chat interface
- On-device inference using Apple MLX
- Model download and retry controls
- Model download and extraction progress
- Persistent model cache in the app's Application Support directory
- Multi-turn chat with selectable responses
- iPhone and iPad support

## Architecture

The project has two runtime layers:

- **SwiftUI app (`ios/QtLlamaSwiftUI`)** — presents the chat, tracks model and
  download state, and manages user interaction.
- **MLX bridge (`ios/MLXQtBridge`)** — downloads and extracts the model, loads
  it with MLX Swift LM, manages the chat session, and generates responses.

```text
SwiftUI views
    │
    ▼
ChatViewModel
    │
    ▼
MLXQtBridge / ModelManager
    ├── downloads and caches the MLX model
    └── runs Qwen3 inference with MLX Swift LM
```

The bridge exposes a native Swift `ModelManager` API. It also exports
C-compatible lifecycle, loading, generation, download, and cancellation
functions for use by other native UI layers.

## Requirements

- An Apple-silicon Mac
- Xcode with Swift 6 support
- iOS 17 or later
- A physical iPhone or iPad recommended for inference
- An Apple development team for device installation
- Approximately 2.1 GB for the model download, plus extraction and runtime
  space
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

A recent device with at least 6 GB of memory is recommended for the four-bit
4B model. The simulator is useful for UI development, but a physical device is
the intended inference target.

## Project structure

```text
.
├── README.md                         Project documentation
├── .gitignore                        Generated and local-file exclusions
├── backend/
│   ├── requirements.txt              Python conversion dependencies
│   ├── src/
│   │   └── convert_to_mlx.py         Hugging Face-to-MLX converter
│   └── tests/
│       └── test_convert_to_mlx.py    Converter unit tests
└── ios/
    ├── Info.plist.in                 Info property-list template
    ├── PrivacyInfo.xcprivacy         App privacy manifest
    ├── MLXQtBridge/                  On-device MLX inference package
    │   ├── Package.swift             Swift package definition
    │   ├── Sources/MLXQtBridge/
    │   │   └── MLXQtBridge.swift     Model download, loading, and inference
    │   └── Tests/MLXQtBridgeTests/
    │       └── ModelManagerTests.swift
    └── QtLlamaSwiftUI/               SwiftUI frontend
        ├── README.md                 iOS-specific setup notes
        ├── Assets.xcassets/          App asset catalog
        │   ├── Contents.json
        │   └── AppIcon.appiconset/
        │       ├── Contents.json
        │       └── AppIcon-1024.png  App icon master artwork
        ├── project.yml               XcodeGen project definition
        ├── Sources/
        │   ├── QtLlamaApp.swift      Application entry point
        │   ├── ContentView.swift     Chat interface
        │   └── ChatViewModel.swift   UI state and bridge integration
        └── Tests/
            └── ChatViewModelTests.swift
```

Python is used only for optional model conversion. The iOS app does not run a
Python service.

## Build and run

1. Generate the Xcode project with the command in the next section.
2. Open `ios/QtLlamaSwiftUI/QtLlamaSwiftUI.xcodeproj` in Xcode.
3. Select the `QtLlamaSwiftUI` target.
4. Under **Signing & Capabilities**, choose your development team and change
   the bundle identifier if needed.
5. Select an iPhone or iPad running iOS 17 or later.
6. Build and run the `QtLlamaSwiftUI` scheme.

The project uses `ios/MLXQtBridge` as a local Swift package. Xcode resolves its
pinned dependencies the first time the project is opened.

After generating the project, verify a simulator build from the repository
root with:

```sh
xcodebuild \
  -project ios/QtLlamaSwiftUI/QtLlamaSwiftUI.xcodeproj \
  -scheme QtLlamaSwiftUI \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### Generate the Xcode project

The Xcode project is generated locally from
`ios/QtLlamaSwiftUI/project.yml` and is not stored in the repository. Install
XcodeGen, then run:

```sh
cd ios/QtLlamaSwiftUI
xcodegen generate
```

## Download and use the model

The repository uses `https://example.com/model.zip` as a placeholder. Before
using **Download model**, update `defaultArchiveURL` in
`ios/MLXQtBridge/Sources/MLXQtBridge/MLXQtBridge.swift` to an HTTPS URL for a
ZIP archive containing the `Qwen3-4B-4bit-mlx` model files.

Library clients can instead provide the URL when creating the manager:

```swift
let manager = ModelManager(
    archiveURL: URL(string: "https://your-host.example/Qwen3-4B-4bit-mlx.zip")!
)
```

1. Launch the app and tap **Download model**.
2. Keep the app in the foreground while the archive downloads and extracts.
3. Wait for the status to change to **Model ready**.
4. Enter a prompt and tap **Send**.

The app downloads the configured archive, extracts `Qwen3-4B-4bit-mlx` into
`Application Support/Models`, and reuses it on later launches. Generation uses
a 512-token maximum response length, a 2,048-token rotating KV cache, and a
temperature of 0.7. Deleting the app or its data removes the cached model.

## Hugging Face-format weights

Hugging Face-format weights are the original model checkpoint files published
in a Hugging Face model repository or saved in an equivalent local directory.
Such a directory normally contains `config.json`, tokenizer files, and one or
more `.safetensors` weight files, with an index file when the weights are
sharded.

For conversion, provide either a repository ID such as `Qwen/Qwen3-4B` or the
path to a local directory containing those files. A GGUF file and an already
converted MLX model are not Hugging Face-format source weights.

MLX creates a smaller model by quantizing the original weights. The default
conversion stores each weight at 4-bit precision instead of the higher
precision used by the source checkpoint, which substantially reduces the
model's download size and runtime memory requirements. Quantization keeps the
same model architecture and parameter count, but represents the parameters
with fewer bits; this can introduce a small loss in output quality. Use
`--bits` to select another supported precision, or `--no-quantize` to retain
the source precision.

## Optional model conversion

The Python utility converts original Hugging Face-format weights to an MLX
model directory on Apple silicon. It does not convert GGUF files.

```sh
cd backend
python3 -m venv .venv-mlx
source .venv-mlx/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
python src/convert_to_mlx.py
```

Run `python src/convert_to_mlx.py --help` for all source model, revision,
output, quantization, and Hugging Face upload options. For example:

```sh
python src/convert_to_mlx.py \
  --model Qwen/Qwen3-4B \
  --revision main \
  --bits 8 \
  --output Qwen/Qwen3-4B-8bit-mlx
```

The converter accepts a Hugging Face repository ID or a local directory with
Hugging Face-format weights. It does not overwrite an existing output
directory. A local conversion does not change the model downloaded by the app;
publish the resulting directory as a ZIP archive and configure its URL as
described above.

## Tests

The Python tests use only the standard library and mock MLX and Hugging Face,
so conversion dependencies are not required:

```sh
python3 -m unittest discover -s backend/tests -v
```

The MLX bridge tests cover unloaded-model behavior and model-directory
validation without downloading or loading model weights:

```sh
swift test --package-path ios/MLXQtBridge
```

After generating the Xcode project, run the SwiftUI unit tests with an
installed simulator:

```sh
xcodebuild test \
  -project ios/QtLlamaSwiftUI/QtLlamaSwiftUI.xcodeproj \
  -scheme QtLlamaSwiftUI \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

Replace the simulator name if `iPhone 16 Pro` is not installed.

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
