// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Capacitor3rddigitalExceptionTracking",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "Capacitor3rddigitalExceptionTracking",
            targets: ["ExceptionTrackingPluginPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0")
    ],
    targets: [
        .target(
            name: "ExceptionTrackingPluginPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm")
            ],
            path: "ios/Sources/ExceptionTrackingPluginPlugin"),
        .testTarget(
            name: "ExceptionTrackingPluginPluginTests",
            dependencies: ["ExceptionTrackingPluginPlugin"],
            path: "ios/Tests/ExceptionTrackingPluginPluginTests")
    ]
)