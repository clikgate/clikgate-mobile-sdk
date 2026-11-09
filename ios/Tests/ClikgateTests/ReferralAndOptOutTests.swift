import XCTest
@testable import Clikgate

final class ReferralTests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared

    override func setUp() { super.setUp(); server.reset(); h = Harness() }
    override func tearDown() { h.cleanUp(); super.tearDown() }

    private func startedCore() async -> ClikgateCore {
        stubHappyPath()
        server.on("POST /v1/sdk/referrals/apply-code", .fixture("referral"))
        server.on("GET /v1/sdk/referrals/referred-by", .fixture("referred_by_response"))
        let core = h.makeCore()
        await core.start(startTimers: false)
        return core
    }

    func testReferralCallSendsIdentityTokenAfterIdentify() async throws {
        let core = await startedCore()
        await core.identifyUser(label: nil, customerId: "user_42", identityToken: "sig.1760954400")
        _ = try await core.referralCall({ ClikgateReferredBy(json: $0) }, method: "GET", path: "v1/sdk/referrals/referred-by", body: nil)
        let req = try XCTUnwrap(server.requests("GET /v1/sdk/referrals/referred-by").first)
        XCTAssertEqual(req.headers["Clikgate-Identity-Token"], "sig.1760954400")
        XCTAssertEqual(server.requests("POST /v1/sdk/identify").first?.json["customer_user_id"] as? String, "user_42")
    }

    func testReferredByAndApplyCode() async throws {
        let core = await startedCore()
        let by = try await core.referralCall({ ClikgateReferredBy(json: $0) }, method: "GET", path: "v1/sdk/referrals/referred-by", body: nil)
        XCTAssertTrue(by.referred)
        XCTAssertEqual(by.referral?.status, "holding")

        let body = JSON.data(["program_id": "rpg_1", "code": "ADA42"])
        let referral = try await core.referralCall({ ClikgateReferral(json: $0) }, method: "POST", path: "v1/sdk/referrals/apply-code", body: body)
        XCTAssertEqual(referral.source, "code_entry")
        XCTAssertNotNil(referral.createdAt)
    }

    func testReferralErrorsSurfaceBackendCodeWithoutRetry() async throws {
        let core = await startedCore()
        server.on("POST /v1/sdk/referrals/apply-code", .fixture("error_code_not_found", status: 404))
        let body = JSON.data(["program_id": "rpg_1", "code": "NOPE"])
        do {
            _ = try await core.referralCall({ ClikgateReferral(json: $0) }, method: "POST", path: "v1/sdk/referrals/apply-code", body: body)
            XCTFail("expected an error")
        } catch let e as ClikgateError {
            XCTAssertEqual(e.code, ClikgateError.codeNotFound)
            XCTAssertEqual(e.status, 404)
            XCTAssertEqual(e.param, "code")
            XCTAssertEqual(e.requestId, "req_01JAB3C4D5E6F7G8H9JKMNPQRS")
        }
        XCTAssertEqual(server.requests("POST /v1/sdk/referrals/apply-code").count, 1)
    }

    func testReferralCallBeforeInstallIsInstallPending() async throws {
        stubHappyPath()
        let core = h.makeCore()
        do {
            _ = try await core.referralCall({ ClikgateReferredBy(json: $0) }, method: "GET", path: "v1/sdk/referrals/referred-by", body: nil)
            XCTFail("expected install_pending")
        } catch let e as ClikgateError {
            XCTAssertEqual(e.code, ClikgateError.installPending)
        }
    }

    func testIdentityInvalidKeepsUserLocally() async throws {
        let core = await startedCore()
        server.on("POST /v1/sdk/identify", .json(#"{"error":{"type":"invalid_request","code":"identity_invalid","message":"bad token"}}"#, status: 422))
        await core.identifyUser(label: nil, customerId: "user_42", identityToken: "bad")
        let s = await core.currentState()
        XCTAssertEqual(s.customerUserId, "user_42")
        XCTAssertFalse(s.identifyPending)
        await core.identifyUser(label: nil, customerId: nil, identityToken: nil)
        let cleared = server.requests("POST /v1/sdk/identify").last?.json
        XCTAssertTrue(cleared?["customer_user_id"] is NSNull, "logout sends explicit null")
    }

    func testPublicReferralsNotConfigured() async {
        // The shared instance in the test process is never configured.
        do { _ = try await Clikgate.shared.referrals.referredBy(); XCTFail() } catch let e as ClikgateError {
            XCTAssertEqual(e.code, ClikgateError.notConfigured)
        } catch { XCTFail() }
        do { _ = try await Clikgate.shared.referrals.applyCode(programId: "rpg_1", code: "  "); XCTFail() } catch let e as ClikgateError {
            XCTAssertEqual(e.code, ClikgateError.invalidArgument)
        } catch { XCTFail() }
    }
}

final class OptOutTests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared

    override func setUp() { super.setUp(); server.reset(); h = Harness() }
    override func tearDown() { h.cleanUp(); super.tearDown() }

    func testOptOutClearsQueueSendsOptOutAndStopsEverythingElse() async throws {
        stubHappyPath()
        let core = h.makeCore()
        await core.start(startTimers: false)
        server.on("POST /v1/sdk/goals", .json("{}", status: 500))
        await core.goal("signup", value: nil, currency: nil, reference: nil, isFirst: nil)
        server.reset(); stubHappyPath()

        await core.setTrackingEnabled(false)
        var queued = await core.queuedEventCount
        XCTAssertEqual(queued, 0)
        XCTAssertEqual(server.requests("POST /v1/sdk/opt-out").first?.json["opt_out"] as? Bool, true)

        await core.goal("purchase", value: nil, currency: nil, reference: nil, isFirst: nil)
        await core.identifyUser(label: nil, customerId: "u", identityToken: nil)
        await core.setPushToken("tok", provider: "fcm")
        await core.resolve(url: URL(string: "https://inv.myapp.com/x")!)
        await core.flush()
        queued = await core.queuedEventCount
        XCTAssertEqual(queued, 0)
        XCTAssertEqual(server.requests.map { $0.key }, ["POST /v1/sdk/opt-out"])

        // Next launch while opted out: nothing at all (not even config).
        server.reset(); stubHappyPath()
        await h.makeCore().start(startTimers: false)
        XCTAssertTrue(server.requests.isEmpty)

        // Opt back in.
        let again = h.makeCore()
        await again.start(startTimers: false)
        await again.setTrackingEnabled(true)
        XCTAssertEqual(server.requests("POST /v1/sdk/opt-out").last?.json["opt_out"] as? Bool, false)
        await again.goal("signup", value: nil, currency: nil, reference: nil, isFirst: nil)
        await again.flush()
        XCTAssertEqual(server.requests("POST /v1/sdk/goals").count, 1)
    }

    func testOptOutIsRetriedUntilItSucceedsAcrossLaunches() async throws {
        stubHappyPath()
        let core = h.makeCore()
        await core.start(startTimers: false)
        server.on("POST /v1/sdk/opt-out", .json(#"{"error":{"type":"x","code":"validation_error","message":"no"}}"#, status: 422))
        await core.setTrackingEnabled(false)
        var pending = await core.currentState().optOutPending
        XCTAssertEqual(pending, true)

        server.reset(); stubHappyPath()
        let next = h.makeCore()
        await next.start(startTimers: false)
        XCTAssertEqual(server.requests.map { $0.key }, ["POST /v1/sdk/opt-out"])
        pending = await next.currentState().optOutPending
        XCTAssertNil(pending)
    }

    func testOptOutBeforeFirstInstallSendsDeniedConsentInstallOnly() async throws {
        h = Harness(pasteboard: FakePasteboard(detect: true, text: "https://x/_cg/p/cgdl_9Xk2abcdefghijklmnopqrstuv"))
        stubHappyPath()
        let core = h.makeCore()
        await core.setTrackingEnabled(false)   // before start / first install
        await core.setPushToken("tok", provider: "fcm")
        await core.start(startTimers: false)
        XCTAssertEqual(server.requests.map { $0.key }, ["POST /v1/sdk/install"])
        let body = try XCTUnwrap(server.requests.first?.json)
        // Change 09 (X.E23): every purpose denied replaces tracking_allowed = false.
        let consent = try XCTUnwrap(body["consent"] as? [String: Any])
        for p in ["analytics", "attribution", "ad_user_data", "ad_personalization"] {
            XCTAssertEqual(consent[p] as? String, "denied", p)
        }
        XCTAssertNil(consent["tracking_allowed"])
        XCTAssertNil(body["pasteboard_token"])
        XCTAssertNil(body["push"])
        XCTAssertNil(body["device_model"])
        XCTAssertEqual(h.pasteboard.detections, 0)
        let a = await core.attribution(timeout: 1)
        XCTAssertEqual(a.status, .organic)
    }

    func testServerOptedOutStopsCalls() async throws {
        stubHappyPath()
        let core = h.makeCore()
        await core.start(startTimers: false)
        server.on("POST /v1/sdk/goals", .json(#"{"error":{"type":"forbidden","code":"opted_out","message":"opted out"}}"#, status: 403))
        await core.goal("goal_a", value: nil, currency: nil, reference: nil, isFirst: nil)
        await core.flush()
        await core.goal("goal_b", value: nil, currency: nil, reference: nil, isFirst: nil)
        await core.flush()
        XCTAssertEqual(server.requests("POST /v1/sdk/goals").count, 1)
        let enabled = await core.currentState().trackingEnabled
        XCTAssertFalse(enabled)
    }
}
