// swift-tools-version: 5.9
// Swift Package Manager support for the plugin's iOS side (Flutter's SPM integration).
// CocoaPods users get the same sources through ../clikgate_flutter.podspec.

import Foundation
import PackageDescription

// Inside the clikgate-mobile-sdk monorepo the native SDK is next door (../../../ios); the
// published plugin (pub.dev) depends on the released Swift package instead.
let monorepoSDK = URL(fileURLWithPath: Context.packageDirectory).appendingPathComponent("../../../ios/Package.swift").standardized.path
let useMonorepo = FileManager.default.fileExists(atPath: monorepoSDK)
let clikgateSDK: Package.Dependency = useMonorepo
    ? .package(path: "../../../ios")
    : .package(url: "https://github.com/clikgate/clikgate-ios-sdk.git", from: "1.5.1")
// SwiftPM identifies a package by its directory / repository name.
let clikgatePackageIdentity = useMonorepo ? "ios" : "clikgate-ios-sdk"

let package = Package(
    name: "clikgate_flutter",
    platforms: [
        .iOS("13.0"),
    ],
    products: [
        .library(name: "clikgate-flutter", targets: ["clikgate_flutter"]),
    ],
    dependencies: [clikgateSDK],
    targets: [
        .target(
            name: "clikgate_flutter",
            dependencies: [.product(name: "Clikgate", package: clikgatePackageIdentity)],
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
    ]
)
