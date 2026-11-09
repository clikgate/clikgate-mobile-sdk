import XCTest
@testable import Clikgate

/// Change 22 (R.22): `/v1/sdk/identify` answers 200 with `verified: false` and a `reason` for a bad identity token;
/// the SDK keeps the customer ID and warns with the reason (never the token or the customer ID). Referral calls
/// refused with `403 identity_expired` are logged the same way.
final class IdentityVerifyTests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared
    private let lock = NSLock()
    private var lines: [String] = []

    override func setUp() {
        super.setUp()
        server.reset()
        h = Harness()
        h.logger.testSink = { [unowned self] m in self.lock.lock(); self.lines.append(m); self.lock.unlock() }
    }

    override func tearDown() { h.logger.testSink = nil; h.cleanUp(); super.tearDown() }

    private var logs: [String] { lock.lock(); defer { lock.unlock() }; return lines }

    private func startedCore() async -> ClikgateCore {
        stubHappyPath()
        let core = h.makeCore()
        await core.start(startTimers: false)
        return core
    }

    private func assertNoSecretsLogged(file: StaticString = #filePath, line: UInt = #line) {
        for m in logs {
            XCTAssertFalse(m.contains("user_42"), m, file: file, line: line)
            XCTAssertFalse(m.contains("sig.1760954400"), m, file: file, line: line)
        }
    }

    func testExpiredTokenKeepsTheCustomerIdAndWarnsWithTheReason() async {
        let core = await startedCore()
        server.on("POST /v1/sdk/identify", .fixture("identify_response_token_expired"))
        await core.identifyUser(label: nil, customerId: "user_42", identityToken: "sig.1760954400")
        let s = await core.currentState()
        XCTAssertEqual(s.customerUserId, "user_42")
        XCTAssertFalse(s.identifyPending)
        XCTAssertEqual(server.requests("POST /v1/sdk/identify").count, 1)
        let warnings = logs.filter { $0.contains("did not verify") }
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("(expired)"))
        XCTAssertTrue(warnings[0].contains("the customer ID is kept but not verified"))
        assertNoSecretsLogged()
    }

    func testVerifiedFalseWithoutATokenIsNotWarned() async {
        let core = await startedCore()
        server.on("POST /v1/sdk/identify",
                  .json(#"{"customer_user_id":"user_42","identity_verified":false,"verified":false,"reason":null}"#))
        await core.identifyUser(label: nil, customerId: "user_42", identityToken: nil)
        XCTAssertEqual(server.requests("POST /v1/sdk/identify").count, 1)
        XCTAssertTrue(logs.allSatisfy { !$0.contains("did not verify") })
    }

    func testOlderServerWithoutVerifiedIsNotWarned() async {
        let core = await startedCore()   // the default identify_response fixture has no `verified`
        await core.identifyUser(label: nil, customerId: "user_42", identityToken: "sig.1760954400")
        XCTAssertEqual(server.requests("POST /v1/sdk/identify").count, 1)
        XCTAssertTrue(logs.allSatisfy { !$0.contains("did not verify") })
    }

    func testEveryReasonReadsInPlainWords() {
        XCTAssertTrue(ClikgateCore.tokenNotVerifiedMessage("expired").contains("(expired)"))
        XCTAssertTrue(ClikgateCore.tokenNotVerifiedMessage("bad_signature").contains("signature"))
        XCTAssertTrue(ClikgateCore.tokenNotVerifiedMessage("secret_rotated").contains("rotated"))
        XCTAssertTrue(ClikgateCore.tokenNotVerifiedMessage("no_secret_set").contains("no identity secret"))
        XCTAssertTrue(ClikgateCore.tokenNotVerifiedMessage("not_yet_valid").contains("future"))
        XCTAssertTrue(ClikgateCore.tokenNotVerifiedMessage(nil).contains("(no reason given)"))
        XCTAssertTrue(ClikgateCore.tokenNotVerifiedMessage("some_new_reason").contains("(some_new_reason)"))
    }

    func testReferralCallRefusedWithIdentityExpiredIsSurfacedAndLogged() async throws {
        let core = await startedCore()
        await core.identifyUser(label: nil, customerId: "user_42", identityToken: "sig.1760954400")
        server.on("GET /v1/sdk/referrals/referred-by",
                  .json(#"{"error":{"type":"forbidden","code":"identity_expired","message":"The identity token has expired."}}"#, status: 403))
        do {
            _ = try await core.referralCall({ ClikgateReferredBy(json: $0) }, method: "GET", path: "v1/sdk/referrals/referred-by", body: nil)
            XCTFail("expected identity_expired")
        } catch let e as ClikgateError {
            XCTAssertEqual(e.code, "identity_expired")
            XCTAssertEqual(e.status, 403)
        }
        XCTAssertEqual(server.requests("GET /v1/sdk/referrals/referred-by").count, 1)
        XCTAssertTrue(logs.contains { $0.contains("identity token has expired (identity_expired)") })
        assertNoSecretsLogged()
    }
}
