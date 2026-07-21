# QtLlamaSwiftUI

QtLlamaSwiftUI is a native iPhone and iPad chat app that runs Qwen3 locally
with [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm). Inference
happens on the device through the local `MLXQtBridge` Swift package; the app
does not require `llama.cpp` or an OpenAI-compatible server.

## Features

- Native SwiftUI chat interface
- On-device model inference with MLX
- Download progress and model-loading status
- Persistent model cache in the app's Application Support directory
- Multi-turn chat session with selectable response text
- iPhone and iPad support

The message field remains visible while the model is unavailable or
downloading, and becomes interactive after the model has downloaded and
loaded successfully.

## Requirements

- An Apple-silicon Mac
- Xcode with Swift 6 support
- iOS 17 or later
- A physical iPhone or iPad recommended for MLX inference
- An Apple development team for device installation
- Approximately 2.1 GB for the model download, plus additional free space for
  extraction and runtime data

A recent device with at least 6 GB of memory is recommended for the four-bit
4B model. The iOS Simulator is useful for UI development, but a physical
Apple-silicon device is the intended inference target.

## Project layout

```text
ios/
├── Assets.xcassets/          Shared app icons and assets
├── MLXQtBridge/              Local Swift package for MLX model operations
├── PrivacyInfo.xcprivacy     Privacy manifest
└── QtLlamaSwiftUI/
    ├── Sources/              SwiftUI app and view model
    ├── project.yml           XcodeGen project definition
    └── QtLlamaSwiftUI.xcodeproj
```

## Build and run

1. Open `QtLlamaSwiftUI.xcodeproj` in Xcode.
2. Select the `QtLlamaSwiftUI` target.
3. Under **Signing & Capabilities**, choose your development team and change
   the bundle identifier if necessary.
4. Select an iPhone or iPad running iOS 17 or later.
5. Build and run the `QtLlamaSwiftUI` scheme.

The project references `../MLXQtBridge` as a local Swift package. Xcode
resolves its pinned remote dependencies when the project is opened for the
first time.

A command-line simulator build can be run from this directory:

```sh
xcodebuild \
  -project QtLlamaSwiftUI.xcodeproj \
  -scheme QtLlamaSwiftUI \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### Regenerate the Xcode project

The checked-in project is generated from `project.yml`. After changing the
project definition, install [XcodeGen](https://github.com/yonaskolb/XcodeGen)
and regenerate it:

```sh
xcodegen generate
```

Do not edit generated project settings directly when the equivalent change
belongs in `project.yml`.

## Download and use the model

1. Launch the app and tap **Download model**.
2. Keep the app in the foreground while the archive downloads and extracts.
3. Wait until the status changes to **Model ready**.
4. Enter a prompt in **Message your model…** and tap **Send**.

The app downloads the `Qwen3-4B-4bit-mlx` archive over HTTPS, extracts it into
`Application Support/Models`, and loads it with MLX Swift LM. A completed
download is reused on later attempts instead of being downloaded again.

Generation uses these defaults:

- Maximum response length: 512 tokens
- Rotating KV cache: 2,048 tokens
- Temperature: 0.7

Deleting the app or its data removes the cached model.

## Optional model conversion

`convert_to_mlx.py` converts original Hugging Face-format weights to MLX on an
Apple-silicon Mac. It cannot convert a GGUF file because GGUF and MLX use
different formats and quantization layouts.

```sh
python3 -m venv .venv-mlx
source .venv-mlx/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements-mlx-convert.txt
python convert_to_mlx.py
```

Run `python convert_to_mlx.py --help` to choose another source model, output
directory, quantization size, group size, revision, or Hugging Face upload
repository. The SwiftUI app's download URL remains configured in
`MLXQtBridge.swift`; producing a local conversion does not automatically
change the model downloaded by the app.

## Troubleshooting

### The message field is disabled

The field is enabled only after the model is fully downloaded and loaded. If
the status says **Download failed**, check the network connection, available
storage, and the error shown in the conversation, then retry after relaunching
the app.

### The app exits while loading or generating

A four-bit 4B model still requires several gigabytes of memory. Close other
memory-intensive apps and try a newer device with more RAM.

### Xcode reports keyboard constraint warnings

Warnings mentioning `com.google.keyboard.KeyboardExtension`,
`_UIKBCompatInputView`, or `TUIKeyboardContentView` originate from a third-party
keyboard extension. Test with Apple's system keyboard to distinguish those
warnings from application layout issues.

### Metal reports unused-variable warnings

Warnings from `mlx/backend/metal/kernels` about unused constants are generated
while MLX compiles its Metal kernels. They are non-fatal when the log also
reports that compilation succeeded.

## Privacy

Prompts and responses are processed locally after the model is installed. A
network connection is required for the initial model and Swift package
downloads. Review `../PrivacyInfo.xcprivacy` and all linked SDK declarations
before distributing the app.
