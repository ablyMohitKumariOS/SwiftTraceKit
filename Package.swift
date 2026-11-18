// swift-tools-version: 6.0
//
// SwiftTraceKit is an in-app debugging toolkit for iOS: network inspector,
// performance monitor (memory, CPU, battery, thermal state) and memory leak
// detector, all reachable from a floating button inside the running app.
//
// Tools version 6.0 keeps the package usable from Xcode 16 onwards.

import PackageDescription

let package = Package(
    name: "SwiftTraceKit",
    platforms: [
        // ContentUnavailableView and the Observation-era SwiftUI APIs used by
        // the dashboard need iOS 17.
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "SwiftTraceKit",
            targets: ["SwiftTraceKit"]
        )
    ],
    targets: [
        .target(
            name: "SwiftTraceKit"
        ),
        .testTarget(
            name: "SwiftTraceKitTests",
            dependencies: ["SwiftTraceKit"]
        )
    ],
    swiftLanguageModes: [.v6]
)
