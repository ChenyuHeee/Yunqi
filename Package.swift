// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Yunqi",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "YunqiApp", targets: ["YunqiApp"]),
        .executable(name: "YunqiMacApp", targets: ["YunqiMacApp"]),
        .library(name: "AudioEngine", targets: ["AudioEngine"]),
        .library(name: "EditorCore", targets: ["EditorCore"]),
        .library(name: "EditorEngine", targets: ["EditorEngine"]),
        .library(name: "MediaIO", targets: ["MediaIO"]),
        .library(name: "RenderEngine", targets: ["RenderEngine"]),
        .library(name: "Storage", targets: ["Storage"]),
        .library(name: "UIBridge", targets: ["UIBridge"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "YunqiApp",
            dependencies: [
                "EditorCore",
                "MediaIO",
                "RenderEngine",
                "Storage"
            ],
            path: "Sources/YunqiApp"
        ),
        .executableTarget(
            name: "YunqiMacApp",
            dependencies: [
                "EditorCore",
                "EditorEngine",
                "RenderEngine",
                "Storage",
                "UIBridge"
            ],
            path: "Sources/YunqiMacApp",
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "AudioEngine",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics")
            ],
            path: "Sources/AudioEngine"
        ),
        .target(
            name: "EditorCore",
            dependencies: [],
            path: "Sources/EditorCore"
        ),
        .target(
            name: "EditorEngine",
            dependencies: [
                "AudioEngine",
                "EditorCore",
                "RenderEngine"
            ],
            path: "Sources/EditorEngine"
        ),
        .target(
            name: "MediaIO",
            dependencies: [
                "AudioEngine"
            ],
            path: "Sources/MediaIO"
        ),
        .target(
            name: "RenderEngine",
            dependencies: [],
            path: "Sources/RenderEngine"
        ),
        .target(
            name: "Storage",
            dependencies: [
                "AudioEngine",
                "EditorCore",
                "MediaIO"
            ],
            path: "Sources/Storage"
        ),
        .target(
            name: "UIBridge",
            dependencies: [
                "EditorCore",
                "EditorEngine",
                "RenderEngine"
            ],
            path: "Sources/UIBridge"
        ),
        .testTarget(
            name: "EditorCoreTests",
            dependencies: [
                "AudioEngine",
                "EditorCore",
                "RenderEngine",
                "Storage"
            ],
            path: "Tests/EditorCoreTests"
        ),
        .testTarget(
            name: "EditorEngineTests",
            dependencies: [
                "EditorCore",
                "EditorEngine",
                "MediaIO",
                "Storage",
                "RenderEngine"
            ],
            path: "Tests/EditorEngineTests",
            resources: [
                .process("Goldens")
            ]
        )
    ]
)
