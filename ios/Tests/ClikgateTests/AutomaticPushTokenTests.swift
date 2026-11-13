import XCTest
@testable import Clikgate

/// `ClikgateOptions.automaticPushToken`: registerForRemoteNotifications() on qualifying launches.
final class AutomaticPushTokenTests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared

    override func setUp() { super.setUp(); server.reset(); h = Harness() }
    override func tearDown() { h.logger.testSink = nil; h.cleanUp(); super.tearDown() }

    private func stubConfig(_ name: String = "config_response", uninstall: Bool = true) {
        var c = Fixtures.json(name)
        var f = c["features"] as! [String: Any]
        f["uninstall_tracking"] = uninstall
        c["features"] = f
        server.on("GET /v1/sdk/config", StubResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: c)))
    }

    private func core(automatic: Bool = true) -> ClikgateCore {
        h.makeCore(options: ClikgateOptions(linkDomains: ["inv.myapp.com"], logLevel: .none, automaticPushToken: automatic))
    }

    private func logs() -> LogBox {
        let box = LogBox()
        h.logger.testSink = { box.append($0) }
        return box
    }

    func testDefaultIsOn() {
        XCTAssertTrue(ClikgateOptions().automaticPushToken)
    }

    func testRegistersOncePerLaunchWhenEverythingAllows() async {
        stubHappyPath(); stubConfig()
        let c = core()
        await c.start(startTimers: false)
        XCTAssertEqual(h.remoteNotifications.calls, 1)
        await c.appWillEnterForeground(startTimers: false)
        await c.setConsent(analytics: .granted, attribution: .granted, adUserData: nil, adPersonalization: nil)
        await c.registerForPushIfNeeded()
        XCTAssertEqual(h.remoteNotifications.calls, 1, "once per launch")

        await core().start(startTimers: false)
        XCTAssertEqual(h.remoteNotifications.calls, 2, "again on the next launch (refreshes rotated tokens)")
    }

    func testOptionOff() async {
        stubHappyPath(); stubConfig()
        await core(automatic: false).start(startTimers: false)
        XCTAssertEqual(h.remoteNotifications.calls, 0)
    }

    func testUninstallTrackingOff() async {
        stubHappyPath(); stubConfig(uninstall: false)
        await core().start(startTimers: false)
        XCTAssertEqual(h.remoteNotifications.calls, 0)
    }

    func testOptedOut() async {
        stubHappyPath(); stubConfig()
        await core().start(startTimers: false)   // earlier launch: install done, config cached
        XCTAssertEqual(h.remoteNotifications.calls, 1)

        let c = core()
        await c.setTrackingEnabled(false)
        await c.start(startTimers: false)
        await c.registerForPushIfNeeded()
        XCTAssertEqual(h.remoteNotifications.calls, 1, "opted out")

        server.on("POST /v1/sdk/opt-out", .json(#"{"opt_out": false}"#))
        await c.setTrackingEnabled(true)
        XCTAssertEqual(h.remoteNotifications.calls, 2, "re-evaluated once tracking is allowed again")
    }

    func testBlockedVersion() async {
        stubHappyPath(); stubConfig("config_response_blocked")
        await core().start(startTimers: false)
        XCTAssertEqual(h.remoteNotifications.calls, 0)
    }

    func testConsentPendingThenGranted() async {
        stubHappyPath(); stubConfig("config_response_consent_required")
        server.on("POST /v1/sdk/consent", .ok)
        let c = core()
        await c.start(startTimers: false)
        XCTAssertEqual(h.remoteNotifications.calls, 0, "consent pending")
        await c.setConsent(analytics: nil, attribution: .granted, adUserData: nil, adPersonalization: nil)
        XCTAssertEqual(h.remoteNotifications.calls, 1, "re-evaluated when consent allows it")
    }

    func testConsentDenied() async {
        stubHappyPath(); stubConfig("config_response_consent_required")
        server.on("POST /v1/sdk/consent", .ok)
        server.on("POST /v1/sdk/install-ping", .ok)
        let c = core()
        await c.setConsent(analytics: .denied, attribution: .denied, adUserData: .denied, adPersonalization: .denied)
        await c.start(startTimers: false)
        XCTAssertEqual(h.remoteNotifications.calls, 0)
    }

    func testManualTokenIsNotOverwritten() async {
        stubHappyPath(); stubConfig()
        let c = core()
        await c.setPushToken("fcm-manual", provider: "fcm")
        await c.start(startTimers: false)
        XCTAssertEqual(h.remoteNotifications.calls, 1)
        let s = await c.state
        XCTAssertEqual(s.pushToken, "fcm-manual")
        XCTAssertEqual(s.pushProvider, "fcm")
    }

    func testDebugLogOnceAndWarningWhenNoTokenArrived() async {
        stubHappyPath(); stubConfig()
        let box = logs()
        await core().start(startTimers: false)
        XCTAssertEqual(box.count("Registered for remote notifications"), 1)
        XCTAssertEqual(box.count("No push token since the last launch"), 0)

        await core().start(startTimers: false)   // next launch, still no token
        XCTAssertEqual(box.count("Registered for remote notifications"), 1, "debug log once")
        XCTAssertEqual(box.count("No push token since the last launch"), 1)
    }

    func testNoWarningOnceATokenArrived() async {
        stubHappyPath(); stubConfig()
        let box = logs()
        let c = core()
        await c.start(startTimers: false)
        await c.setPushToken("a1b2c3d4", provider: "apns")
        await core().start(startTimers: false)
        XCTAssertEqual(box.count("No push token since the last launch"), 0)
    }

    func testNoWarningWhenConditionsDontHold() async {
        stubHappyPath(); stubConfig()
        let box = logs()
        await core().start(startTimers: false)
        await core(automatic: false).start(startTimers: false)
        XCTAssertEqual(box.count("No push token since the last launch"), 0)
        XCTAssertEqual(h.remoteNotifications.calls, 1)
    }
}

final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    func count(_ prefix: String) -> Int { lock.lock(); defer { lock.unlock() }; return items.filter { $0.hasPrefix(prefix) }.count }
}
