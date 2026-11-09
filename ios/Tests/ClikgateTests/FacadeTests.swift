import XCTest
@testable @_spi(ClikgateWrapper) import Clikgate

/// Public API on isolated `Clikgate` instances (not `.shared`) with the test harness dependencies.
final class FacadeTests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared

    override func setUp() { super.setUp(); server.reset(); h = Harness() }
    override func tearDown() { h.cleanUp(); super.tearDown() }

    private func make() -> Clikgate {
        let sdk = Clikgate()
        sdk.configure(sdkKey: "cg_sdk_test", options: ClikgateOptions(linkDomains: ["inv.myapp.com"], logLevel: .none),
                      deps: h.deps(), startTimers: false)
        return sdk
    }

    func testURLsBeforeConfigureAreHandledAfterConfigure() async throws {
        stubHappyPath(install: "install_response_organic")
        let sdk = Clikgate()
        let box = ResultBox()
        sdk.onDeepLink { box.append($0) }
        XCTAssertFalse(sdk.handle(url: URL(string: "https://inv.myapp.com/p/dress")!), "unknown before configure")
        XCTAssertFalse(sdk.isConfigured)
        sdk.configure(sdkKey: "cg_sdk_test", options: ClikgateOptions(linkDomains: ["inv.myapp.com"], logLevel: .none),
                      deps: h.deps(), startTimers: false)
        XCTAssertTrue(sdk.isConfigured)
        await eventually { box.items.count == 1 }
        XCTAssertEqual(box.items.first?.path, "/products/42")
    }

    func testHandleURLDecisionAndUserActivity() async throws {
        stubHappyPath()
        let sdk = make()
        XCTAssertTrue(sdk.handle(url: URL(string: "https://inv.myapp.com/p/dress")!))
        XCTAssertFalse(sdk.handle(url: URL(string: "https://example.com/p/dress")!))
        XCTAssertTrue(sdk.handle(url: URL(string: "myapp://p?cg_click_id=clk_1")!))
        XCTAssertFalse(sdk.handle(url: URL(string: "myapp://p")!))
        let ua = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        ua.webpageURL = URL(string: "https://inv.myapp.com/r/ADA42")
        XCTAssertTrue(sdk.continue(userActivity: ua))
    }

    func testInstallationIdViaFacade() async throws {
        // Change 22 (I.7, R.26): `try await Clikgate.shared.installationId()`; the completion form for wrappers.
        stubHappyPath()
        let unconfigured = Clikgate()
        do { _ = try await unconfigured.installationId(); XCTFail("expected not_configured") } catch let e as ClikgateError {
            XCTAssertEqual(e.code, ClikgateError.notConfigured)
        }
        let sdk = make()
        let id = try await sdk.installationId()
        XCTAssertNotNil(id)
        let stored = await sdk.currentCore?.currentState().installationId
        XCTAssertEqual(id, stored, "the ID the SDK sends to Clikgate")
        let box = ErrorBox()
        let ids = IdBox()
        sdk.installationId { r in
            switch r {
            case .success(let v): ids.value = v
            case .failure(let e): box.set(e)
            }
            ids.done = true
        }
        await eventually { ids.done }
        XCTAssertNil(box.value)
        XCTAssertEqual(ids.value, id)
    }

    func testAttributionCompletionAndReferralsViaFacade() async throws {
        stubHappyPath(install: "install_response_referral")
        server.on("GET /v1/sdk/referrals/referred-by", .fixture("referred_by_response"))
        let sdk = make()
        // The fake clock makes the attribution timeout instant, so wait for /install first.
        for _ in 0..<300 {
            if let c = sdk.currentCore, await c.currentState().installDone { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let a = try await sdk.attribution()
        XCTAssertEqual(a.status, .attributed)
        XCTAssertEqual(a.clickedAtRaw, "2026-10-20T09:59:00Z")
        let by = try await sdk.referrals.referredBy()
        XCTAssertEqual(by.referral?.createdAtRaw, "2026-10-20T10:00:01Z")
    }

    func testNotConfiguredErrors() async {
        let sdk = Clikgate()
        do { _ = try await sdk.attribution(); XCTFail() } catch let e as ClikgateError {
            XCTAssertEqual(e.code, ClikgateError.notConfigured)
        } catch { XCTFail() }
    }

    func testInvalidKeyIsRejectedAtConfigure() {
        let sdk = Clikgate()
        sdk.configure(sdkKey: "not-a-key", options: ClikgateOptions(logLevel: .none), deps: h.deps(), startTimers: false)
        XCTAssertFalse(sdk.isConfigured)
    }
}

final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: ClikgateError?
    private var _done = false
    func set(_ e: ClikgateError?) { lock.lock(); _value = e; _done = true; lock.unlock() }
    var value: ClikgateError? { lock.lock(); defer { lock.unlock() }; return _value }
    var done: Bool { lock.lock(); defer { lock.unlock() }; return _done }
}

final class IdBox: @unchecked Sendable {
    var value: String?
    var done = false
}
