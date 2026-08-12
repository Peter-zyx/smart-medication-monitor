// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MedBoxProtocol",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MedBoxProtocol", targets: ["MedBoxProtocol"])
    ],
    targets: [
        .target(name: "MedBoxProtocol"),
        .testTarget(
            name: "MedBoxProtocolTests",
            dependencies: ["MedBoxProtocol"]
        )
    ]
)

