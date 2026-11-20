// swift-tools-version: 6.0
// NotAnIslandKit: the SDK for building Not an Island extensions. Licensed GPL-3.0, like the app.
import PackageDescription

let package = Package(
    name: "NotAnIslandKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NotAnIslandKit", targets: ["NotAnIslandKit"]),
    ],
    targets: [
        .target(name: "NotAnIslandKit", path: "NotAnIslandKit/Sources/NotAnIslandKit"),
        .testTarget(
            name: "NotAnIslandKitTests",
            dependencies: ["NotAnIslandKit"],
            path: "NotAnIslandKit/Tests/NotAnIslandKitTests"
        ),
    ]
)
