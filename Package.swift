// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Yunqi",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "YunqiApp", targets: ["YunqiApp"]),
        .executable(name: "YunqiMacApp", targets: ["YunqiMacApp"]),
        .library(name: "EditorCore", targets: ["EditorCore"]),
        .library(name: "MediaIO", targets: ["MediaIO"]),
        .library(name: "RenderEngine", targets: ["RenderEngine"]),
        .library(name: "Storage", targets: ["Storage"]),
        .library(name: "UIBridge", targets: ["UIBridge"])
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
                "RenderEngine",
                "Storage",
                "UIBridge"
            ],
            path: "Sources/YunqiMacApp"
        ),
        .target(
            name: "EditorCore",
            dependencies: [
                "RenderEngine"
            ],
            path: "Sources/EditorCore"
        ),
        .target(
            name: "MediaIO",
            dependencies: [],
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
                "EditorCore"
            ],
            path: "Sources/Storage"
        ),
        .target(
            name: "UIBridge",
            dependencies: [
                "EditorCore",
                "RenderEngine"
            ],
            path: "Sources/UIBridge"
        ),
        .testTarget(
            name: "EditorCoreTests",
            dependencies: ["EditorCore"],
            path: "Tests/EditorCoreTests"
        )
    ]
)
