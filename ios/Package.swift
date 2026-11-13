// swift-tools-version:5.9
import PackageDescription

// One product, `Clikgate` (since 2.1.0), with two modules:
// - `Clikgate`: the core SDK. It never depends on ClikgateEngage.
// - `ClikgateEngage`: the Engage features for apps without their own backend (referral link + stats,
//   leaderboards, promo codes, share helpers). Depends on Clikgate; apps `import ClikgateEngage` to use them.
//   The two modules stay separate so the core keeps its own size budget (< 410 KB) and boundary checks.
let package = Package(
    name: "Clikgate",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "Clikgate", targets: ["Clikgate", "ClikgateEngage"]),
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
