// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "MLXQtBridge",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "MLXQtBridge", targets: ["MLXQtBridge"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm",
            exact: "3.31.3"
        ),
        .package(
            url: "https://github.com/DePasqualeOrg/swift-tokenizers-mlx",
            exact: "0.3.0"
        ),
        // 0.6+ changed encode/decode to throwing APIs before the 0.3.0 MLX
        // adapter was updated. Keep the mutually compatible tokenizer API.
        .package(
            url: "https://github.com/DePasqualeOrg/swift-tokenizers",
            exact: "0.5.0"
        ),
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            exact: "0.9.20"
        ),
    ],
    targets: [
        .target(
            name: "MLXQtBridge",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLMTokenizers", package: "swift-tokenizers-mlx"),
                .product(name: "Tokenizers", package: "swift-tokenizers"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
    ]
)
