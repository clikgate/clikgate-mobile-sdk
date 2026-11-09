import XCTest
@_spi(ClikgateWrapper) @testable import Clikgate

/// Change 10 (D.5, contract B3a.2): deep links on, attribution off (Free, Starter, or an app with
/// attribution switched off). goal() warns once ("switched off") and does nothing; the
/// server's `feature_disabled` answer on /goals is never retried; the "no deferred link"
/// install result at the monthly cap is a normal empty result.
final class DeepLinkOnlyTests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared

    override func setUp() {
        super.setUp()
        server.reset()
        h = Harness()
        stubHappyPath()
        server.on("POST /v1/sdk/goals", .fixture("goals_response"))
    }

    override func tearDown() {
        h.cleanUp()
        super.tearDown()
    }

    private func calls(_ key: String) -> Int { server.requests(key).count }

    func testConfigWithAttributionOffSkipsGoals() async {
        server.on("GET /v1/sdk/config", .fixture("config_response_deep_link_only"))
        let core = h.makeCore()
        await core.start(startTimers: false)
        XCTAssertFalse(core.features.isEnabled(ClikgateFeatures.appAttribution))
        XCTAssertTrue(core.features.isEnabled("deep_linking"))

        await core.goal("purchase", value: nil, currency: nil, reference: nil, isFirst: nil)
        await core.goal("account_opened", value: nil, currency: nil, reference: "APP-1", isFirst: nil)
        await core.flush()

        let queued = await core.queuedEventCount
        XCTAssertEqual(queued, 0)
        XCTAssertEqual(calls("POST /v1/sdk/goals"), 0)
        let warned = await core.needsGrowthWarned
        XCTAssertTrue(warned)
    }

    func testFacadeGoalIsRefusedWithoutAnError() async {
        server.on("GET /v1/sdk/config", .fixture("config_response_deep_link_only"))
        let sdk = Clikgate()
        sdk.configure(sdkKey: "cg_sdk_test", options: ClikgateOptions(linkDomains: ["yourapp.clk.ng"], logLevel: .none),
                      deps: h.deps(), startTimers: false)
        // Wait for the cached config to say deep-link-only.
        for _ in 0..<300 {
            if !sdk.isFeatureEnabled(ClikgateFeatures.appAttribution) { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let goal: ClikgateGoalResult = await withCheckedContinuation { cont in
            sdk.goal("account_opened", reference: "APP-1") { cont.resume(returning: $0) }
        }
        XCTAssertEqual(goal, .refused("feature_disabled"))
    }

    func testFeatureDisabledOnGoalsIsDroppedNotRetried() async {
        server.on("GET /v1/sdk/config", .fixture("config_response"), .fixture("config_response_deep_link_only"))
        server.on("POST /v1/sdk/goals", .fixture("goals_response_feature_disabled"))
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.goal("account_opened", value: nil, currency: nil, reference: "APP-1", isFirst: nil)
        await core.flush()
        XCTAssertEqual(calls("POST /v1/sdk/goals"), 1, "no retry")
        let queued = await core.queuedEventCount
        XCTAssertEqual(queued, 0)
        let warned = await core.needsGrowthWarned
        XCTAssertTrue(warned)
        XCTAssertFalse(core.features.isEnabled(ClikgateFeatures.appAttribution))

        // Later calls stop on the device.
        await core.goal("order_paid", value: nil, currency: nil, reference: "ORD-1", isFirst: nil)
        await core.flush()
        XCTAssertEqual(calls("POST /v1/sdk/goals"), 1)
    }

    func testDeferredDeepLinkIsDeliveredWithOrganicAttribution() async throws {
        server.on("GET /v1/sdk/config", .fixture("config_response_deep_link_only"))
        server.on("POST /v1/sdk/install", .fixture("install_response_deep_link_only"))
        let box = collect(h.dispatcher)
        let core = h.makeCore(options: ClikgateOptions(linkDomains: ["yourapp.clk.ng"], logLevel: .none))
        await core.start(startTimers: false)
        await eventually { box.items.count == 1 }
        let r = try XCTUnwrap(box.items.first)
        XCTAssertTrue(r.isDeferred)
        XCTAssertEqual(r.path, "/products/42")
        let a = await core.attribution(timeout: 1)
        XCTAssertEqual(a.status, .organic)
        XCTAssertNil(a.link)
    }

    func testNoDeferredLinkAtTheCapIsANormalEmptyResult() async {
        server.on("GET /v1/sdk/config", .fixture("config_response_deep_link_only"))
        server.on("POST /v1/sdk/install", .fixture("install_response_deferred_cap"))
        server.on("POST /v1/sdk/resolve", .fixture("resolve_response_unmatched"))
        let box = collect(h.dispatcher)
        let core = h.makeCore(options: ClikgateOptions(linkDomains: ["yourapp.clk.ng"], logLevel: .none))
        await core.start(startTimers: false)
        let a = await core.attribution(timeout: 1)
        XCTAssertEqual(a.status, .organic)
        XCTAssertEqual(box.items.count, 0)
        XCTAssertEqual(calls("POST /v1/sdk/install"), 1, "no retry")
        let state = await core.currentState()
        XCTAssertTrue(state.installDone)
    }
}
