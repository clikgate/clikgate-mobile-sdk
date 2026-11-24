import XCTest
@_spi(ClikgateEngage) import Clikgate
@testable import ClikgateEngage

/// `referrals.myStats` without waiting for the install or identify, and `referrals.myLink`.
final class MyStatsAndLinkTests: XCTestCase {
    static let program = "rpg_01JAB3C4D5E6F7G8H9JKMNPQRS"
    static let me = "GET /v1/sdk/referrals/me"
    var rig: EngageRig!

    override func setUp() { super.setUp(); rig = EngageRig() }

    private func errorBody(_ code: String, _ status: Int) -> FakeReply {
        .json(#"{"error":{"type":"invalid_request","code":"\#(code)","message":"msg"}}"#, status: status)
    }

    private func header(_ i: Int) -> String? {
        rig.transport.requests(Self.me)[i].request.value(forHTTPHeaderField: "Clikgate-Customer-User-Id")
    }

    // MARK: myStats

    func testMyStatsSendsAtOnceWithTheCustomerHeaderWhileTheInstallIsPending() async throws {
        rig.host.holdWaiting = true
        rig.host.customerUserId = "usér 42/%"
        rig.transport.on(Self.me, .fixture("referral_stats_response"))
        let s = try await rig.referrals.myStats(programId: Self.program)
        XCTAssertEqual(s.code, "ADA42X")
        XCTAssertEqual(header(0), "us%C3%A9r%2042%2F%25")
        XCTAssertEqual(rig.transport.requests(Self.me)[0].request.value(forHTTPHeaderField: "Clikgate-Identity-Token"), "sig.1760954400")
        XCTAssertEqual(rig.host.noWaitCalls, 1)
        XCTAssertEqual(rig.host.contextCalls, 0)
    }

    func testMyStatsCacheIsPerCustomer() async throws {
        rig.transport.on(Self.me, .fixture("referral_stats_response"))
        _ = try await rig.referrals.myStats(programId: Self.program)
        _ = try await rig.referrals.myStats(programId: Self.program)
        XCTAssertEqual(rig.transport.requests(Self.me).count, 1)
        rig.host.customerUserId = "user_43"
        _ = try await rig.referrals.myStats(programId: Self.program)
        XCTAssertEqual(rig.transport.requests(Self.me).count, 2)
        XCTAssertEqual(header(1), "user_43")
    }

    func testMyStatsFallsBackOnceThroughTheWaitingPath() async throws {
        for (code, status) in [("installation_unknown", 404), ("not_identified", 403)] {
            rig = EngageRig()
            rig.transport.on(Self.me, errorBody(code, status), .fixture("referral_stats_response"))
            rig.host.holdWaiting = true
            let referrals = rig.referrals
            let task = Task { try await referrals.myStats(programId: Self.program) }
            await waitUntil { self.rig.host.contextCalls == 1 }
            XCTAssertEqual(rig.transport.requests(Self.me).count, 1, "the retry waits for the install")
            rig.host.releaseWaiting()
            _ = try await task.value
            XCTAssertEqual(rig.transport.requests(Self.me).count, 2)
            XCTAssertEqual(header(0), "user_42")
            XCTAssertNil(header(1))
            XCTAssertTrue(rig.host.reports.isEmpty, "the retried code is not reported")
        }
    }

    func testMyStatsFallsBackOnlyOnce() async throws {
        rig.transport.on(Self.me, errorBody("not_identified", 403))
        _ = await expectEngageError(ClikgateError.notIdentified) { try await rig.referrals.myStats(programId: Self.program) }
        XCTAssertEqual(rig.transport.requests(Self.me).count, 2)
    }

    func testMyStatsOtherErrorsAreReturnedAsIs() async throws {
        rig.transport.on(Self.me, errorBody("identity_invalid", 422))
        _ = await expectEngageError("identity_invalid") { try await rig.referrals.myStats(programId: Self.program) }
        XCTAssertEqual(rig.transport.requests(Self.me).count, 1)
        XCTAssertEqual(rig.host.contextCalls, 0)
    }

    func testMyStatsWithoutATokenWaitsAsBefore() async throws {
        rig.host.identityToken = nil
        rig.host.holdWaiting = true
        rig.transport.on(Self.me, .fixture("referral_stats_response"))
        let referrals = rig.referrals
        let task = Task { try await referrals.myStats(programId: Self.program) }
        await waitUntil { self.rig.host.contextCalls == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(rig.transport.requests.isEmpty)
        rig.host.releaseWaiting()
        _ = try await task.value
        XCTAssertNil(header(0))
    }

    func testOtherCallsKeepWaiting() async throws {
        rig.transport.on("POST /v1/sdk/referrals/link", .fixture("referral_link_response"))
        _ = try await rig.referrals.createLink(programId: Self.program)
        XCTAssertEqual(rig.host.noWaitCalls, 0)
        XCTAssertNil(rig.transport.requests[0].request.value(forHTTPHeaderField: "Clikgate-Customer-User-Id"))
    }

    // MARK: myLink

    func testMyLinkFirstCallFetchesAndSaves() async throws {
        rig.transport.on(Self.me, .fixture("referral_stats_response"))
        let link = try await rig.referrals.myLink(programId: Self.program)
        XCTAssertEqual(link.code, "ADA42X")
        XCTAssertEqual(link.url, "https://inv.myapp.com/r/ADA42X")
        XCTAssertEqual(link.shortUrl, "https://inv.myapp.com/a8K2bq")
        XCTAssertEqual(header(0), "user_42")
        XCTAssertEqual(rig.host.savedLink(Self.program).0?["code"] as? String, "ADA42X")
    }

    func testMyLinkAnswersTheSavedLinkThenRefreshesAtMostOncePerMinute() async throws {
        rig.host.saveLink(Self.program, EFixtures.json("referral_link_response"), token: "user_42")
        rig.host.holdWaiting = true
        rig.transport.on(Self.me, .offline)
        let link = try await rig.referrals.myLink(programId: Self.program)
        XCTAssertEqual(link.code, "ADA42X")
        await waitUntil { self.rig.transport.requests(Self.me).count >= 1 }
        _ = try await rig.referrals.myLink(programId: Self.program)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(rig.transport.requests(Self.me).count, 2, "one refresh (one network retry) within 60 s")
        rig.clock.advance(60)
        _ = try await rig.referrals.myLink(programId: Self.program)
        await waitUntil { self.rig.transport.requests(Self.me).count == 4 }
    }

    func testMyLinkRefreshUpdatesAChangedUrl() async throws {
        rig.host.saveLink(Self.program, EFixtures.json("referral_link_response"), token: "user_42")
        var renamed = EFixtures.json("referral_stats_response")
        renamed["url"] = "https://go.myapp.com/r/ADA42X"
        renamed["short_url"] = "https://go.myapp.com/a8K2bq"
        let body = String(data: try JSONSerialization.data(withJSONObject: renamed), encoding: .utf8)!
        rig.transport.on(Self.me, .json(body))
        let first = try await rig.referrals.myLink(programId: Self.program)
        XCTAssertEqual(first.url, "https://inv.myapp.com/r/ADA42X")
        await waitUntil { self.rig.host.savedLink(Self.program).0?["url"] as? String == "https://go.myapp.com/r/ADA42X" }
        let next = try await rig.referrals.myLink(programId: Self.program)
        XCTAssertEqual(next.url, "https://go.myapp.com/r/ADA42X")
        XCTAssertEqual(next.shortUrl, "https://go.myapp.com/a8K2bq")
    }

    func testMyLinkSavedLinksAreKeptPerCustomer() async throws {
        rig.host.saveLink(Self.program, EFixtures.json("referral_link_response"), token: "user_42")
        rig.host.customerUserId = "user_77"
        rig.transport.on(Self.me, errorBody("referrer_not_found", 404))
        _ = await expectEngageError("referrer_not_found") { try await rig.referrals.myLink(programId: Self.program) }
        XCTAssertEqual(header(0), "user_77")
    }

    func testMyLinkNeedsAnIdentifiedUser() async throws {
        rig.host.customerUserId = nil
        rig.host.identityToken = nil
        rig.host.holdWaiting = true
        _ = await expectEngageError(ClikgateError.notIdentified) { try await rig.referrals.myLink(programId: Self.program) }
        XCTAssertTrue(rig.transport.requests.isEmpty)
        XCTAssertEqual(rig.host.contextCalls, 0, "no wait")
    }

    func testMyLinkSwitchedOff() async throws {
        rig.host.saveLink(Self.program, EFixtures.json("referral_link_response"), token: "user_42")
        rig.host.disabled = ["referrals"]
        _ = await expectEngageError(ClikgateError.featureDisabled) { try await rig.referrals.myLink(programId: Self.program) }
        XCTAssertTrue(rig.transport.requests.isEmpty)
    }

    func testMyStatsSavesTheLink() async throws {
        rig.transport.on(Self.me, .fixture("referral_stats_response"))
        _ = try await rig.referrals.myStats(programId: Self.program)
        rig.transport.on(Self.me, .offline)
        let link = try await rig.referrals.myLink(programId: Self.program)
        XCTAssertEqual(link.code, "ADA42X")
    }
}
