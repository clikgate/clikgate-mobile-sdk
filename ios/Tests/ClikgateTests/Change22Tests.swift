import XCTest
@testable import Clikgate

/// Change 22: one method, `goal()` (R.9 `received`; R.5 no conversion values from goals), and
/// `installationId()` for identity Path B (I.7, R.26).
final class Change22Tests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared

    override func setUp() {
        super.setUp()
        server.reset()
        h = Harness()
        stubHappyPath()
    }

    override func tearDown() {
        h.cleanUp()
        super.tearDown()
    }

    private func config(_ name: String) { server.on("GET /v1/sdk/config", .fixture(name)) }

    private var sentInstallationId: String? { server.requests("POST /v1/sdk/install").first?.json["installation_id"] as? String }

    // MARK: - R.9 received

    func testReceivedIsASuccessAndIsNotRetried() async {
        server.on("POST /v1/sdk/goals", .fixture("goals_response_received"))
        let core = h.makeCore()
        await core.start(startTimers: false)
        let results = GoalResults()
        await core.goal("level_completed", value: nil, currency: nil, reference: "APP-7", isFirst: nil, done: { results.add($0, "new") })
        await core.goal("old_signup", value: nil, currency: nil, reference: "APP-8", isFirst: nil, done: { results.add($0, "archived") })
        await core.flush()
        XCTAssertEqual(results.byKey["new"], ClikgateGoalResult(status: .received, reason: "not_counted_yet", goalKind: nil, valueIgnored: false))
        XCTAssertEqual(results.byKey["archived"], ClikgateGoalResult(status: .received, reason: "goal_archived", goalKind: .standard, valueIgnored: false))
        let left = await core.queuedEventCount
        XCTAssertEqual(left, 0)
        await core.flush()
        XCTAssertEqual(server.requests("POST /v1/sdk/goals").count, 1)
    }

    // MARK: - R.5 no SKAdNetwork / AdAttributionKit values

    func testAConfigStillCarryingAConversionValueSchemaIsIgnored() async {
        var c = Fixtures.json("config_response")
        c["conversion_value_schema"] = ["id": "cvs_1", "version": 1, "rules": [["fine_value": 1, "coarse_value": "low", "event": "signup"]]]
        server.on("GET /v1/sdk/config", StubResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: c)))
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.goal("signup", value: nil, currency: nil, reference: "S1", isFirst: nil)
        await core.flush()
        XCTAssertEqual(server.requests("POST /v1/sdk/goals").count, 1)
        let st = await core.currentState()
        XCTAssertNil(st.json["skan_last_fine_value"])
    }

    // MARK: - R.6 deeplink_handled for App banner taps in live mode

    func testLiveModeReportsTheRightScreenForABannerTapThatMeasuresIt() async throws {
        server.on("POST /v1/sdk/deeplink-handled", .fixture("deeplink_handled_response"))
        server.on("POST /v1/sdk/resolve", .fixture("resolve_response_banner_right_screen"))
        let core = h.makeCore(sdkKey: "cg_sdk_live_4f1c9a")
        await core.start(startTimers: false)
        await core.resolve(url: URL(string: "https://inv.myapp.com/products/42?ref=banner")!)
        await eventually { self.server.requests("POST /v1/sdk/deeplink-handled").count == 1 }
        XCTAssertEqual(server.requests("POST /v1/sdk/deeplink-handled").first?.json as NSDictionary?,
                       Fixtures.json("deeplink_handled_request_banner") as NSDictionary)
        let queued = await core.queuedEventCount
        XCTAssertEqual(queued, 0, "never queued, never a goal")
    }

    func testLiveModeWithoutTheBannerFlagReportsNothing() async {
        server.on("POST /v1/sdk/deeplink-handled", .fixture("deeplink_handled_response"))
        let links = collect(h.dispatcher)
        let core = h.makeCore(sdkKey: "cg_sdk_live_4f1c9a")
        await core.start(startTimers: false)
        await core.resolve(url: URL(string: "https://inv.myapp.com/products/42")!)
        await eventually { links.items.count >= 1 }
        await drainMain()
        XCTAssertTrue(server.requests("POST /v1/sdk/deeplink-handled").isEmpty)
    }

    // MARK: - installationId()

    func testInstallationIdIsTheOneSentToClikgateAndStable() async {
        let core = h.makeCore()
        await core.start(startTimers: false)
        let id = await core.installationIdForApp()
        XCTAssertNotNil(id)
        XCTAssertEqual(id, sentInstallationId)
        let next = h.makeCore()
        await next.start(startTimers: false)
        let again = await next.installationIdForApp()
        XCTAssertEqual(again, id)
    }

    func testCalledBeforeStartItCreatesTheSameId() async {
        let core = h.makeCore()
        let early = await core.installationIdForApp()   // before the first launch's work began
        await core.start(startTimers: false)
        XCTAssertNotNil(early)
        XCTAssertEqual(early, sentInstallationId)
    }

    func testOfflineFirstLaunchStillAnswers() async {
        // No config and no network yet (the first launch's work hasn't reached the server): answered from the device.
        // (start() isn't awaited here: with the fake clock an offline /install would retry without end.)
        server.on("GET /v1/sdk/config", .offline())
        server.on("POST /v1/sdk/install", .offline())
        let core = h.makeCore()
        let id = await core.installationIdForApp()
        XCTAssertNotNil(id)
        XCTAssertTrue(server.requests.isEmpty, "no network call needed")
    }

    func testAReinstallGetsANewIdAndKeepsThePreviousOneForTheServer() async {
        h = Harness(keychain: "11111111-2222-4333-8444-555555555555")
        let core = h.makeCore()
        let id = await core.installationIdForApp()
        XCTAssertNotNil(id)
        XCTAssertNotEqual(id, "11111111-2222-4333-8444-555555555555")
        let st = await core.currentState()
        XCTAssertEqual(st.keychainPreviousInstallationId, "11111111-2222-4333-8444-555555555555")
    }

    func testNilAfterOptOutAndBackAfterOptIn() async {
        let core = h.makeCore()
        await core.start(startTimers: false)
        let id = await core.installationIdForApp()
        await core.setTrackingEnabled(false)
        let off = await core.installationIdForApp()
        XCTAssertNil(off)
        await core.setTrackingEnabled(true)
        let on = await core.installationIdForApp()
        XCTAssertEqual(on, id)
    }

    func testNilWhileConsentIsRequiredAndNotGrantedNorAfterDenial() async {
        config("config_response_consent_required")
        let core = h.makeCore()
        await core.start(startTimers: false)
        var id = await core.installationIdForApp()
        XCTAssertNil(id, "unknown in a required region")
        await core.setConsent(analytics: nil, attribution: .denied, adUserData: nil, adPersonalization: nil)
        id = await core.installationIdForApp()
        XCTAssertNil(id)
        await core.setConsent(analytics: nil, attribution: .granted, adUserData: nil, adPersonalization: nil)
        id = await core.installationIdForApp()
        XCTAssertNotNil(id)
    }

    func testNilInDeepLinkOnlyMode() async {
        config("config_response_deep_link_only")
        let core = h.makeCore()
        await core.start(startTimers: false)
        let id = await core.installationIdForApp()
        XCTAssertNil(id)
    }

    func testAllowedInPrivateMode() async {
        config("config_response_private_mode")
        let core = h.makeCore()
        await core.start(startTimers: false)
        let id = await core.installationIdForApp()
        XCTAssertEqual(id, sentInstallationId)
    }
}
