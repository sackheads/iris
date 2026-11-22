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
        // An exact tag, not a branch (#1083): the MCP provider depends on `StatelessHTTPServerTransport`'s
        // validation pipeline, per-instance `Server` state and `withMethodHandler` behaviour of this
        // release. Moving it is a deliberate edit here, with the provider's suites re-run.
        // #1116: 0.12.1 plus one change, `HTTPClientTransport.init(endpoint:session:...)` made public, so
        // Iris can give remote MCP servers a session with a redirect policy. Switch back to the upstream
        // release once that change ships there (upstream issue/PR linked from #1116).
        .package(url: "https://github.com/sackheads/swift-sdk.git", revision: "1971631fa83108da6c6d24ff7945a4e8f55186b2"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
        .package(url: "https://github.com/mattt/llama.swift.git", branch: "main"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", branch: "main"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", branch: "main"),
        // #1322: microsoft/onnxruntime-swift-package-manager was removed and download.onnxruntime.ai stopped serving
        // a valid certificate, so this is our mirror: upstream 1.24.2 plus one commit pointing the two binary targets at
        // the mirror's release assets (byte-identical, checksums unchanged). Pinned at 1.24.2 until upstream returns.
        .package(url: "https://github.com/sackheads/onnxruntime-swift-package-manager", revision: "def1e49e06770d4bd70a85160f98b78abf9f1b6d"),
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
                .product(name: "Sparkle", package: "Sparkle"),
                "CIrisSignals"
            ],
            resources: [
                .process("assets")
            ]
        ),
        // The CLI's signal handler, in C so it is async-signal-safe by construction (#510).
        .target(name: "CIrisSignals"),
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
