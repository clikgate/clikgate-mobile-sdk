import XCTest
import UIKit
@_spi(ClikgateEngage) import Clikgate
@testable import ClikgateEngage

/// Engage add-on (spec 17A) against a fake core host and a fake transport.
final class ClikgateEngageTests: XCTestCase {
    static let board = "lb_01JAB3C4D5E6F7G8H9JKMNPQRS"
    static let program = "rpg_01JAB3C4D5E6F7G8H9JKMNPQRS"
    var rig: EngageRig!

    override func setUp() { super.setUp(); rig = EngageRig() }

    // MARK: 17A.3 rule 1: feature switch first, no network

    func testSwitchedOffFeaturesFailWithoutNetworkOrContext() async throws {
        rig.host.disabled = ["referrals", "leaderboards", "offline_codes"]
        let e1 = await expectEngageError(ClikgateError.featureDisabled) { try await rig.referrals.createLink(programId: Self.program) }
        XCTAssertEqual(e1?.feature, "referrals")
        _ = await expectEngageError(ClikgateError.featureDisabled) { try await rig.referrals.myStats(programId: Self.program) }
        let e2 = await expectEngageError(ClikgateError.featureDisabled) { try await rig.leaderboards.top(id: Self.board) }
        XCTAssertEqual(e2?.feature, "leaderboards")
        _ = await expectEngageError(ClikgateError.featureDisabled) { try await rig.leaderboards.me(id: Self.board) }
        _ = await expectEngageError(ClikgateError.featureDisabled) { try await rig.leaderboards.aroundMe(id: Self.board) }
        _ = await expectEngageError(ClikgateError.featureDisabled) { try await rig.leaderboards.setOptOut(programId: Self.program, optOut: true) }
        _ = await expectEngageError(ClikgateError.featureDisabled) { try await rig.leaderboards.hostedPageUrl(id: Self.board) }
        let e3 = await expectEngageError(ClikgateError.featureDisabled) { try await rig.codes.redeem("LAGOS50") }
        XCTAssertEqual(e3?.feature, "offline_codes")
        XCTAssertTrue(rig.transport.requests.isEmpty)
        XCTAssertEqual(rig.host.contextCalls, 0)
    }

    // MARK: Context errors and identity

    func testContextErrorsPropagate() async throws {
        rig.host.contextError = ClikgateError(code: ClikgateError.installPending, message: "x")
        _ = await expectEngageError(ClikgateError.installPending) { try await rig.leaderboards.top(id: Self.board) }
        rig.host.contextError = ClikgateError(code: ClikgateError.notConfigured, message: "x")
        _ = await expectEngageError(ClikgateError.notConfigured) { try await rig.codes.redeem("LAGOS50") }
        XCTAssertTrue(rig.transport.requests.isEmpty)
    }

    func testUserCallsNeedAnIdentifiedInstallation() async throws {
        rig.host.customerUserId = nil
        rig.host.identityToken = nil
        _ = await expectEngageError(ClikgateError.notIdentified) { try await rig.referrals.createLink(programId: Self.program) }
        _ = await expectEngageError(ClikgateError.notIdentified) { try await rig.referrals.myStats(programId: Self.program) }
        _ = await expectEngageError(ClikgateError.notIdentified) { try await rig.leaderboards.me(id: Self.board) }
        _ = await expectEngageError(ClikgateError.notIdentified) { try await rig.leaderboards.aroundMe(id: Self.board) }
        _ = await expectEngageError(ClikgateError.notIdentified) { try await rig.leaderboards.setOptOut(programId: Self.program, optOut: true) }
        _ = await expectEngageError(ClikgateError.notIdentified) { try await rig.leaderboards.hostedPageUrl(id: Self.board) }
        XCTAssertTrue(rig.transport.requests.isEmpty)

        // top and redeem don't need a user.
        rig.transport.on("GET /v1/sdk/leaderboards/\(Self.board)", .fixture("leaderboard_page"))
        rig.transport.on("POST /v1/sdk/codes/redeem", .fixture("code_redemption_response"))
        _ = try await rig.leaderboards.top(id: Self.board)
        _ = try await rig.codes.redeem("LAGOS50")
        XCTAssertNil(rig.transport.requests[0].request.value(forHTTPHeaderField: "Clikgate-Identity-Token"))
    }

    func testIdentityRequiredComesFromTheServer() async throws {
        rig.transport.on("POST /v1/sdk/referrals/link", .json(
            #"{"error":{"type":"forbidden","code":"identity_required","message":"Verified identity required.","param":null}}"#, status: 403))
        let e = await expectEngageError("identity_required") { try await rig.referrals.createLink(programId: Self.program) }
        XCTAssertEqual(e?.status, 403)
        XCTAssertEqual(rig.transport.requests.count, 1, "not retried")
    }

    // MARK: Requests and decoding

    func testHeadersFromTheCoreContext() async throws {
        rig.transport.on("POST /v1/sdk/referrals/link", .fixture("referral_link_response"))
        let link = try await rig.referrals.createLink(programId: Self.program, displayName: "Ada")
        XCTAssertEqual(link.code, "ADA42X")
        XCTAssertEqual(link.shortUrl, "https://inv.myapp.com/a8K2bq")
        let r = try XCTUnwrap(rig.transport.requests.first)
        XCTAssertEqual(r.request.url?.absoluteString, "https://sdk.example.test/v1/sdk/referrals/link")
        XCTAssertEqual(r.request.value(forHTTPHeaderField: "Clikgate-SDK-Key"), "cg_sdk_test_abc")
        XCTAssertEqual(r.request.value(forHTTPHeaderField: "Clikgate-SDK-Version"), "flutter/1.0.0")
        XCTAssertEqual(r.request.value(forHTTPHeaderField: "Clikgate-SDK-Native-Version"), "ios/1.0.0")
        XCTAssertEqual(r.request.value(forHTTPHeaderField: "Clikgate-Installation-Id"), "6a1f0c2e-0000-4000-8000-000000000001")
        XCTAssertEqual(r.request.value(forHTTPHeaderField: "Clikgate-Identity-Token"), "sig.1760954400")
        XCTAssertEqual(r.request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
        XCTAssertEqual(r.json as NSDictionary, ["program_id": Self.program, "display_name": "Ada"])
        XCTAssertEqual(r.request.timeoutInterval, 10)
    }

    func testMyStats() async throws {
        rig.transport.on("GET /v1/sdk/referrals/me", .fixture("referral_stats_response"))
        let s = try await rig.referrals.myStats(programId: "rpg_1")
        XCTAssertEqual(s.clicks, 12); XCTAssertEqual(s.inProgress, 1); XCTAssertEqual(s.rejected, 1)
        XCTAssertEqual(rig.transport.requests.first?.query, "program_id=rpg_1")
    }

    func testTopMeAroundMeAndOptOut() async throws {
        let t = rig.transport
        t.on("GET /v1/sdk/leaderboards/\(Self.board)", .fixture("leaderboard_page"))
        let page = try await rig.leaderboards.top(id: Self.board, period: .previous, segment: "lagos", limit: 500)
        XCTAssertEqual(t.requests.last?.query, "period=previous&segment=lagos&limit=100", "limit clamped to 100")
        XCTAssertEqual(page.name, "Weekly top inviters")
        XCTAssertEqual(page.period.key, "2026-W43")
        XCTAssertEqual(page.period.startsAtRaw, "2026-10-19T23:00:00Z")
        XCTAssertNotNil(page.period.endsAt)
        XCTAssertEqual(page.entries.count, 2)
        XCTAssertEqual(page.entries[0].display, "Ada O.")
        XCTAssertTrue(page.entries[1].isMe)
        _ = try await rig.leaderboards.top(id: Self.board, period: "2026-W42", limit: 0)
        XCTAssertEqual(t.requests.last?.query, "period=2026-W42&limit=1")

        t.on("GET /v1/sdk/leaderboards/\(Self.board)/me", .fixture("my_rank"))
        let me = try await rig.leaderboards.me(id: Self.board)
        XCTAssertEqual(t.requests.last?.query, "period=current")
        XCTAssertEqual(me.rank, 2); XCTAssertEqual(me.gapToNext, 3); XCTAssertFalse(me.optedOut)
        XCTAssertNil(me.embedUrl)
        XCTAssertNotNil(me.periodEndsAt)

        var around = EFixtures.json("leaderboard_page")
        around["name"] = nil; around["metric"] = nil; around["segment"] = nil
        let data = String(data: try JSONSerialization.data(withJSONObject: around), encoding: .utf8)!
        t.on("GET /v1/sdk/leaderboards/\(Self.board)/around-me", .json(data))
        let a = try await rig.leaderboards.aroundMe(id: Self.board, radius: 99)
        XCTAssertEqual(t.requests.last?.query, "radius=25&period=current")
        XCTAssertNil(a.name)

        t.on("POST /v1/sdk/leaderboards/opt-out", .json(#"{"program_id":"rpg_1","opt_out":true}"#))
        try await rig.leaderboards.setOptOut(programId: Self.program, optOut: true)
        XCTAssertEqual(t.requests.last?.json as NSDictionary?, ["program_id": Self.program, "opt_out": true])
    }

    func testHostedPageUrlFromEmbedUrl() async throws {
        var body = EFixtures.json("my_rank")
        body["embed_token"] = "emb_abc"
        body["embed_url"] = "https://inv.myapp.com/leaderboard/\(Self.board)?me=emb_abc"
        let data = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8)!
        rig.transport.on("GET /v1/sdk/leaderboards/\(Self.board)/me", .json(data))
        let url = try await rig.leaderboards.hostedPageUrl(id: Self.board)
        XCTAssertEqual(url.absoluteString, "https://inv.myapp.com/leaderboard/\(Self.board)?me=emb_abc")
        XCTAssertEqual(rig.transport.requests.last?.query, "period=current&embed=1")
        // Never cached: a second call asks again.
        _ = try await rig.leaderboards.hostedPageUrl(id: Self.board)
        XCTAssertEqual(rig.transport.requests.count, 2)

        rig.transport.on("GET /v1/sdk/leaderboards/\(Self.board)/me", .fixture("my_rank"))   // embed_url null
        _ = await expectEngageError(ClikgateError.hostedPageUnavailable) { try await rig.leaderboards.hostedPageUrl(id: Self.board) }
    }

    func testRedeem() async throws {
        rig.transport.on("POST /v1/sdk/codes/redeem", .fixture("code_redemption_response"))
        let r = try await rig.codes.redeem("  lagos50 ")
        XCTAssertEqual(rig.transport.requests.last?.json as NSDictionary?, ["code": "lagos50"])
        XCTAssertEqual(r.offlineTouchId, "oft_01JAB3C4D5E6F7G8H9JKMNPQRS")
        XCTAssertEqual(r.code.code, "LAGOS50")
        XCTAssertNil(r.referral)

        var body = EFixtures.json("code_redemption_response")
        body["code"] = ["code": "ADA42X", "kind": "referral", "referrer_id": "rfr_1", "program_id": "rpg_1"]
        body["referral"] = EFixtures.json("referral")
        let data = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8)!
        rig.transport.on("POST /v1/sdk/codes/redeem", .json(data))
        let ref = try await rig.codes.redeem("ADA42X")
        XCTAssertEqual(ref.code.kind, "referral")
        XCTAssertEqual(ref.referral?.source, "code_entry")
    }

    func testValidationBeforeAnything() async throws {
        _ = await expectEngageError(ClikgateError.invalidArgument) { try await rig.codes.redeem(" ab ") }
        _ = await expectEngageError(ClikgateError.invalidArgument) { try await rig.codes.redeem(String(repeating: "A", count: 31)) }
        let e = await expectEngageError(ClikgateError.invalidArgument) { try await rig.leaderboards.top(id: "  ") }
        XCTAssertEqual(e?.param, "leaderboard_id")
        _ = await expectEngageError(ClikgateError.invalidArgument) { try await rig.leaderboards.me(id: "a/b") }
        _ = await expectEngageError(ClikgateError.invalidArgument) { try await rig.leaderboards.me(id: Self.board, period: "") }
        _ = await expectEngageError(ClikgateError.invalidArgument) { try await rig.referrals.createLink(programId: " ") }
        XCTAssertEqual(rig.host.contextCalls, 0)
    }

    // MARK: Errors

    func testErrorMappingAndReports() async throws {
        rig.transport.on("POST /v1/sdk/codes/redeem", .json(
            #"{"error":{"type":"conflict","code":"already_referred","message":"Already referred.","param":null,"request_id":"req_1","offline_touch_id":"oft_2"}}"#, status: 409))
        let e = await expectEngageError(ClikgateError.alreadyReferred) { try await rig.codes.redeem("ADA42X") }
        XCTAssertEqual(e?.offlineTouchId, "oft_2")
        XCTAssertEqual(e?.requestId, "req_1")
        XCTAssertTrue(rig.host.reports.isEmpty)

        rig.transport.on("GET /v1/sdk/leaderboards/lb_x", .fixture("error_code_not_found", status: 404))
        _ = await expectEngageError(ClikgateError.codeNotFound) { try await rig.leaderboards.top(id: "lb_x") }

        rig.transport.on("GET /v1/sdk/leaderboards/lb_y", .json(#"{"error":{"type":"auth","code":"invalid_sdk_key","message":"bad"}}"#, status: 401))
        _ = await expectEngageError(ClikgateError.invalidSdkKey) { try await rig.leaderboards.top(id: "lb_y") }
        XCTAssertEqual(rig.host.reports.last?.code, ClikgateError.invalidSdkKey)

        rig.transport.on("GET /v1/sdk/leaderboards/lb_z", .json(#"{"unexpected": true}"#))
        _ = await expectEngageError(ClikgateError.serverError) { try await rig.leaderboards.top(id: "lb_z") }
    }

    func testFeatureDisabledBodyIsReportedToTheCore() async throws {
        rig.transport.on("GET /v1/sdk/leaderboards/\(Self.board)", .fixture("feature_disabled"))
        let e = await expectEngageError(ClikgateError.featureDisabled) { try await rig.leaderboards.top(id: Self.board) }
        XCTAssertEqual(e?.feature, "leaderboards")
        XCTAssertEqual(rig.host.reports.map(\.code), [ClikgateError.featureDisabled])
        XCTAssertEqual(rig.host.reports.first?.feature, "leaderboards")

        // Body naming another feature: both are reported.
        rig.transport.on("POST /v1/sdk/codes/redeem", .fixture("feature_disabled"))
        _ = await expectEngageError(ClikgateError.featureDisabled) { try await rig.codes.redeem("LAGOS50") }
        XCTAssertEqual(rig.host.reports.suffix(2).map(\.feature), ["leaderboards", "offline_codes"])
    }

    // MARK: 17A.3 rule: at most one retry, network errors only

    func testOneRetryForNetworkErrorsOnly() async throws {
        rig.transport.on("GET /v1/sdk/leaderboards/\(Self.board)", .offline, .fixture("leaderboard_page"))
        _ = try await rig.leaderboards.top(id: Self.board)
        XCTAssertEqual(rig.transport.requests.count, 2)
        XCTAssertEqual(rig.clock.sleeps, [EngageClient.networkRetryDelay])

        rig.transport.on("GET /v1/sdk/leaderboards/\(Self.board)/me", .offline)
        _ = await expectEngageError(ClikgateError.networkError) { try await rig.leaderboards.me(id: Self.board) }
        XCTAssertEqual(rig.transport.requests("GET /v1/sdk/leaderboards/\(Self.board)/me").count, 2, "one retry")

        let unavailable = FakeReply.json(#"{"error":{"type":"server_error","code":"server_error","message":"x"}}"#, status: 503)
        rig.transport.on("POST /v1/sdk/codes/redeem", unavailable, .fixture("code_redemption_response"))
        _ = await expectEngageError(ClikgateError.serverError) { try await rig.codes.redeem("LAGOS50") }
        XCTAssertEqual(rig.transport.requests("POST /v1/sdk/codes/redeem").count, 1, "no retry on 5xx")

        rig.transport.on("GET /v1/sdk/referrals/me", .fixture("error_rate_limited", status: 429))
        _ = await expectEngageError(ClikgateError.rateLimited) { try await rig.referrals.myStats(programId: "rpg_1") }
        XCTAssertEqual(rig.transport.requests("GET /v1/sdk/referrals/me").count, 1, "no retry on 429")
    }

    // MARK: 17A.3 rule: 60 s in-memory read cache

    func testReadsAreCachedFor60Seconds() async throws {
        let t = rig.transport
        t.on("GET /v1/sdk/leaderboards/\(Self.board)", .fixture("leaderboard_page"))
        _ = try await rig.leaderboards.top(id: Self.board)
        _ = try await rig.leaderboards.top(id: Self.board)
        XCTAssertEqual(t.requests.count, 1, "served from the cache")
        _ = try await rig.leaderboards.top(id: Self.board, limit: 10)
        XCTAssertEqual(t.requests.count, 2, "different query = different entry")

        rig.clock.advance(59)
        _ = try await rig.leaderboards.top(id: Self.board)
        XCTAssertEqual(t.requests.count, 2)
        rig.clock.advance(2)
        _ = try await rig.leaderboards.top(id: Self.board)
        XCTAssertEqual(t.requests.count, 3, "expired after 60 s")

        // Another user: separate entry.
        rig.host.customerUserId = "user_43"
        _ = try await rig.leaderboards.top(id: Self.board)
        XCTAssertEqual(t.requests.count, 4)

        // A write clears the cache.
        t.on("POST /v1/sdk/leaderboards/opt-out", .json(#"{"program_id":"rpg_1","opt_out":true}"#))
        try await rig.leaderboards.setOptOut(programId: Self.program, optOut: true)
        _ = try await rig.leaderboards.top(id: Self.board)
        XCTAssertEqual(t.requests("GET /v1/sdk/leaderboards/\(Self.board)").count, 5)

        // clearCache().
        rig.client.clearCache()
        _ = try await rig.leaderboards.top(id: Self.board)
        XCTAssertEqual(t.requests("GET /v1/sdk/leaderboards/\(Self.board)").count, 6)

        // Errors aren't cached; the feature check runs before the cache.
        t.on("GET /v1/sdk/referrals/me", .offline, .offline, .fixture("referral_stats_response"))
        _ = await expectEngageError(ClikgateError.networkError) { try await rig.referrals.myStats(programId: "rpg_1") }
        _ = try await rig.referrals.myStats(programId: "rpg_1")
        rig.host.disabled = ["leaderboards"]
        _ = await expectEngageError(ClikgateError.featureDisabled) { try await rig.leaderboards.top(id: Self.board) }
    }

    func testCompletionVariantsRunOnMain() async throws {
        rig.transport.on("POST /v1/sdk/codes/redeem", .fixture("code_redemption_response"))
        let flag = Flag()
        rig.codes.redeem("LAGOS50") { r in
            XCTAssertTrue(Thread.isMainThread)
            if case .success(let v) = r, v.code.code == "LAGOS50" { flag.set() }
        }
        await waitUntil { flag.value }
    }

    // MARK: Share

    func testWhatsAppURLEncoding() throws {
        let url = try XCTUnwrap(ClikgateEngageShare.whatsAppURL(text: "Join me & save 10% = ₦500? https://inv.myapp.com/r/ADA42X?x=1#y"))
        XCTAssertEqual(url.absoluteString,
                       "whatsapp://send?text=Join%20me%20%26%20save%2010%25%20%3D%20%E2%82%A6500%3F%20https%3A%2F%2Finv.myapp.com%2Fr%2FADA42X%3Fx%3D1%23y")
        let back = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value
        XCTAssertEqual(back, "Join me & save 10% = ₦500? https://inv.myapp.com/r/ADA42X?x=1#y")
    }

    @MainActor
    func testWhatsAppOpensWhenAvailableElseShareSheet() async throws {
        let share = ClikgateEngageShare()
        let ui = FakeShareUI(canOpen: true)
        share.ui = ui
        let opened = try await share.whatsApp(text: "Join me: https://inv.myapp.com/r/ADA42X")
        XCTAssertTrue(opened)
        XCTAssertEqual(ui.opened, [ClikgateEngageShare.whatsAppURL(text: "Join me: https://inv.myapp.com/r/ADA42X")!])
        XCTAssertEqual(ui.sheetCount, 0)

        let noScheme = FakeShareUI(canOpen: false)
        share.ui = noScheme
        let viaSheet = try await share.whatsApp(text: "hi")
        XCTAssertFalse(viaSheet)
        XCTAssertEqual(noScheme.firstSheetText, "hi")

        let openFails = FakeShareUI(canOpen: true, openResult: false)
        share.ui = openFails
        let r = try await share.whatsApp(text: "hi")
        XCTAssertFalse(r)
        XCTAssertEqual(openFails.sheetCount, 1)

        share.ui = FakeShareUI(canOpen: false, canPresent: false)
        _ = await expectEngageError(ClikgateError.shareUnavailable) { try await share.whatsApp(text: "hi") }
        XCTAssertThrowsError(try share.system(text: "hi"))

        let sheet = FakeShareUI()
        share.ui = sheet
        try share.system(text: "Join me")
        XCTAssertEqual(sheet.firstSheetText, "Join me")
    }

    // MARK: Live wiring

    func testLiveHostUsesTheSharedCore() async {
        // Clikgate.shared is never configured in the test process.
        _ = await expectEngageError(ClikgateError.notConfigured) { try await ClikgateEngage.leaderboards.top(id: Self.board) }
        ClikgateEngage.clearCache()
        XCTAssertFalse(ClikgateEngage.version.isEmpty)
    }
}
