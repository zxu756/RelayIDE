// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RelayMergeEval",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "relay-merge-eval", targets: ["RelayMergeEval"])
    ],
    dependencies: [
        .package(name: "RelayIDE", path: "../../..")
    ],
    targets: [
        .executableTarget(
            name: "RelayMergeEval",
            dependencies: [
                .product(name: "RelayModels", package: "RelayIDE"),
                .product(name: "RelaySemanticMerge", package: "RelayIDE")
            ]
        )
    ]
)
