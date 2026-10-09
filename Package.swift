// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "iris",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "IrisKit", targets: ["IrisKit"]),
        .executable(name: "iris", targets: ["iris"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", branch: "main"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
        .package(url: "https://github.com/mattt/llama.swift.git", branch: "main"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", branch: "main"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", branch: "main"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.20.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "IrisKit",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "LlamaSwift", package: "llama.swift"),
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [
                .process("assets")
            ]
        ),
        .executableTarget(
            name: "iris",
            dependencies: ["IrisKit"]
        ),
        .testTarget(
            name: "irisTests",
            dependencies: ["IrisKit", .product(name: "MCP", package: "swift-sdk")],
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
