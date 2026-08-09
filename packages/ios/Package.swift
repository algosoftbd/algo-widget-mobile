// swift-tools-version: 5.9
import PackageDescription

// iOS capture core for the Algo Widget (docs/PROTOCOL.md).
//
// Deliberately thin — see AlgoWidgetCapture.swift. Everything that can be done
// above the platform lives in the Flutter and React Native packages, where it
// can be tested without a device.
let package = Package(
    name: "AlgoWidget",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "AlgoWidget", targets: ["AlgoWidget"])
    ],
    targets: [
        .target(name: "AlgoWidget"),
        .testTarget(name: "AlgoWidgetTests", dependencies: ["AlgoWidget"]),
    ]
)
