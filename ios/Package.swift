// swift-tools-version:5.9
import PackageDescription

// Two products:
// - `Clikgate`: the core SDK (required). It never depends on ClikgateEngage.
// - `ClikgateEngage`: the optional Engage add-on for apps without their own backend
//   (referral link + stats, leaderboards, promo codes, share helpers). Depends on Clikgate.
let package = Package(
    name: "Clikgate",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "Clikgate", targets: ["Clikgate"]),
        .library(name: "ClikgateEngage", targets: ["ClikgateEngage"]),
    ],
    targets: [
        .target(
            name: "Clikgate",
            path: "Sources/Clikgate",
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "ClikgateEngage",
            dependencies: ["Clikgate"],
            path: "Sources/ClikgateEngage",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "ClikgateTests",
            dependencies: ["Clikgate"],
            path: "Tests/ClikgateTests",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "ClikgateEngageTests",
            dependencies: ["ClikgateEngage", "Clikgate"],
            path: "Tests/ClikgateEngageTests",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
