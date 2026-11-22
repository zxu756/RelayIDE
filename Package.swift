// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RelayIDE",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "RelayModels", targets: ["RelayModels"]),
        .library(name: "RelayPTYCore", targets: ["RelayPTYCore"]),
        .library(name: "RelayWorktreeGit", targets: ["RelayWorktreeGit"]),
        .library(name: "RelaySemanticMerge", targets: ["RelaySemanticMerge"]),
        .library(name: "RelayWorkspaceStore", targets: ["RelayWorkspaceStore"]),
        .library(name: "RelayPluginSDK", targets: ["RelayPluginSDK"]),
        .library(name: "RelayOrchestrator", targets: ["RelayOrchestrator"]),
        .library(name: "RelayCLIAndMCP", targets: ["RelayCLIAndMCP"]),
        .library(name: "RelayWorkbenchShell", targets: ["RelayWorkbenchShell"]),
        .library(name: "RelayStudioViews", targets: ["RelayStudioViews"]),
        .executable(name: "RelayIDE", targets: ["RelayIDE"])
    ],
    targets: [
        .target(
            name: "RelayModels",
            dependencies: []
        ),
        .target(
            name: "RelayPTYCore",
            dependencies: ["RelayModels"]
        ),
        .target(
            name: "RelayWorktreeGit",
            dependencies: ["RelayModels"],
            linkerSettings: [
                .linkedFramework("CoreServices")
            ]
        ),
        .target(
            name: "RelaySemanticMerge",
            dependencies: ["RelayModels"]
        ),
        .target(
            name: "RelayWorkspaceStore",
            dependencies: ["RelayModels"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "RelayPluginSDK",
            dependencies: [
                "RelayModels",
                "RelaySemanticMerge"
            ],
            linkerSettings: [
                .linkedFramework("JavaScriptCore")
            ]
        ),
        .target(
            name: "RelayOrchestrator",
            dependencies: [
                "RelayModels",
                "RelayPTYCore",
                "RelayWorktreeGit",
                "RelaySemanticMerge",
                "RelayWorkspaceStore",
                "RelayPluginSDK"
            ]
        ),
        .target(
            name: "RelayCLIAndMCP",
            dependencies: [
                "RelayModels",
                "RelayPTYCore",
                "RelayWorktreeGit",
                "RelayWorkspaceStore",
                "RelayPluginSDK",
                "RelayOrchestrator"
            ]
        ),
        .target(
            name: "RelayWorkbenchShell",
            dependencies: [
                "RelayModels",
                "RelayWorkspaceStore",
                "RelayPluginSDK"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .target(
            name: "RelayStudioViews",
            dependencies: [
                "RelayModels",
                "RelayPTYCore",
                "RelayWorktreeGit",
                "RelaySemanticMerge",
                "RelayWorkspaceStore",
                "RelayPluginSDK",
                "RelayOrchestrator",
                "RelayCLIAndMCP",
                "RelayWorkbenchShell"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreServices"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .executableTarget(
            name: "RelayIDE",
            dependencies: [
                "RelayModels",
                "RelayPTYCore",
                "RelayWorktreeGit",
                "RelayWorkspaceStore",
                "RelayPluginSDK",
                "RelayOrchestrator",
                "RelayCLIAndMCP",
                "RelayWorkbenchShell",
                "RelayStudioViews"
            ]
        ),
        .testTarget(
            name: "RelayIDETests",
            dependencies: [
                "RelayModels",
                "RelayPTYCore",
                "RelayWorktreeGit",
                "RelaySemanticMerge",
                "RelayWorkspaceStore",
                "RelayPluginSDK",
                "RelayOrchestrator",
                "RelayCLIAndMCP",
                "RelayWorkbenchShell",
                "RelayStudioViews"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("PDFKit")
            ]
        )
    ]
)
