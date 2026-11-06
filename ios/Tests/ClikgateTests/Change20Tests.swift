import XCTest
@testable import Clikgate

/// Change 20 (S.1, R.40): `deeplink_handled` reports the handled deep link's path for the live check, with IDs,
/// emails and phone numbers replaced on the device; only in test mode or while the debug view is open; never
/// queued, metered or counted as an event.
final class Change20Tests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared
    let testKey = "cg_sdk_test_4f1c9a"
    let liveKey = "cg_sdk_live_4f1c9a"
    let route = "POST /v1/sdk/deeplink-handled"

    override func setUp() {
        super.setUp()
        server.reset()
        h = Harness()
        stubHappyPath()
        server.on(route, .fixture("deeplink_handled_response"))
    }

    override func tearDown() {
        h.cleanUp()
        super.tearDown()
    }

    private func reports() -> [[String: Any]] { server.requests(route).map { $0.json } }

    private func started(_ key: String) async -> ClikgateCore {
        let core = h.makeCore(sdkKey: key)
        await core.start(startTimers: false)
        return core
    }

    func testPathCasesFromTheSharedVectors() {
        let cases = Fixtures.json("deeplink_path_cases")["cases"] as! [[String: String]]
        XCTAssertGreaterThan(cases.count, 20)
        for c in cases { XCTAssertEqual(DeepLinkPath.clean(c["path"]!), c["expected"]!, c["path"]!) }
    }

    func testTestModeReportsTheDirectLinkPathWithIdsReplaced() async throws {
        let links = collect(h.dispatcher)
        let core = await started(testKey)
        await core.resolve(url: URL(string: "https://inv.myapp.com/p/dress?utm_source=x")!)
        await eventually { self.reports().count == 1 }
        XCTAssertEqual(reports().first as NSDictionary?, Fixtures.json("deeplink_handled_request") as NSDictionary)
        await eventually { links.items.count == 1 }
        XCTAssertEqual(links.items.first?.path, "/products/42", "the app still gets the real path")
        let r = try XCTUnwrap(server.requests(route).first)
        XCTAssertEqual(r.headers["Clikgate-SDK-Key"], testKey)
        XCTAssertNil(r.headers["Idempotency-Key"])
    }

    func testQueryFragmentEmailAndUuidNeverLeaveTheDevice() async throws {
        server.on("POST /v1/sdk/resolve", .fixture("resolve_response_debug_view"))
        let core = await started(testKey)
        await core.resolve(url: URL(string: "https://inv.myapp.com/p/dress")!)
        await eventually { self.reports().count == 1 }
        XCTAssertEqual(reports().first?["path"] as? String, "/u/:id/orders/:id")
        let raw = String(data: server.requests(route)[0].body ?? Data(), encoding: .utf8) ?? ""
        for leaked in ["ada", "example.com", "8f14e45f", "coupon", "SAVE10", "top"] { XCTAssertFalse(raw.contains(leaked), leaked) }
    }

    func testDeferredLinkIsReportedAsDeferred() async throws {
        server.on("POST /v1/sdk/install", .fixture("install_response_deep_link_only"))
        let links = collect(h.dispatcher)
        _ = await started(testKey)
        await eventually { self.reports().count == 1 }
        XCTAssertEqual(reports().first as NSDictionary?, Fixtures.json("deeplink_handled_request_deferred") as NSDictionary)
        await eventually { links.items.count == 1 }
    }

    func testLiveModeSendsNothingWithoutTheDebugView() async throws {
        server.on("POST /v1/sdk/install", .fixture("install_response_deep_link_only"))
        let links = collect(h.dispatcher)
        let core = await started(liveKey)
        await core.resolve(url: URL(string: "https://inv.myapp.com/p/dress")!)
        await eventually { links.items.count == 2 }
        await drainMain()
        XCTAssertTrue(server.requests(route).isEmpty)
    }

    func testLiveModeReportsWhileTheDebugViewIsOpen() async throws {
        server.on("POST /v1/sdk/install", .fixture("install_response_debug_view"))
        server.on("POST /v1/sdk/resolve", .fixture("resolve_response_debug_view"))
        let core = await started(liveKey)
        await eventually { self.reports().count == 1 }
        await core.resolve(url: URL(string: "https://inv.myapp.com/p/dress")!)
        await eventually { self.reports().count == 2 }
        XCTAssertEqual(reports().map { $0["is_deferred"] as? Bool }, [true, false])
    }

    /// Not metered: never an `/events` or `/goals` item, never queued; sent in deep-link-only and private mode.
    func testNeverQueuedOrSentAsAnEvent() async throws {
        for config in ["config_response_deep_link_only", "config_response_private_mode"] {
            server.reset()
            stubHappyPath()
            server.on(route, .fixture("deeplink_handled_response"))
            server.on("GET /v1/sdk/config", .fixture(config))
            let h2 = Harness()
            let core = h2.makeCore(sdkKey: testKey)
            await core.start(startTimers: false)
            await core.resolve(url: URL(string: "https://inv.myapp.com/p/dress")!)
            await eventually { self.reports().count == 1 }
            await core.flush()
            let queued = await core.queuedEventCount
            XCTAssertEqual(queued, 0, config)
            let sent = server.requests("POST /v1/sdk/events") + server.requests("POST /v1/sdk/goals")
            XCTAssertFalse(sent.contains { String(data: $0.body ?? Data(), encoding: .utf8)?.contains("deeplink") ?? false }, config)
            h2.cleanUp()
        }
    }

    func testAFailedReportIsDroppedAfterOneRetry() async throws {
        server.on(route, .json(#"{"error":{"type":"api_error","code":"server_error","message":"x"}}"#, status: 503))
        let core = await started(testKey)
        await core.resolve(url: URL(string: "https://inv.myapp.com/p/dress")!)
        await eventually(timeout: 6) { self.server.requests(self.route).count == 2 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(server.requests(route).count, 2)
        let queued = await core.queuedEventCount
        XCTAssertEqual(queued, 0)
    }

    func testBlockedLinkIsNotReported() async throws {
        server.on("POST /v1/sdk/resolve", .fixture("resolve_response_blocked"))
        let links = collect(h.dispatcher)
        let core = await started(testKey)
        await core.resolve(url: URL(string: "https://inv.myapp.com/offer")!)
        await eventually { links.items.count == 1 }
        await drainMain()
        XCTAssertTrue(server.requests(route).isEmpty)
    }

    func testNothingWhileConsentIsPending() async throws {
        server.on("GET /v1/sdk/config", .fixture("config_response_consent_required"))
        let links = collect(h.dispatcher)
        let core = await started(testKey)
        await core.resolve(url: URL(string: "https://inv.myapp.com/p/dress")!)
        await eventually { links.items.count == 1 }   // delivered locally
        await drainMain()
        XCTAssertTrue(server.requests(route).isEmpty)
    }
}
