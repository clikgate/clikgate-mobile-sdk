import XCTest
@testable import Clikgate

/// Change 26 (existing users): what the first `/install` says about when the app arrived (EX.3, R.1, R.3, R.4),
/// the hint (R.23), Apple's app record (KC.6, R.14), the existing-user error (RF.1), the server's wait with jitter
/// (R.11) and the saved referral links the core keeps for Engage (R.28).
final class Change26Tests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared
    // 2025-03-02T09:17:45Z
    let installedAt = Date(timeIntervalSince1970: 1_740_907_065)

    override func setUp() {
        super.setUp()
        server.reset()
        h = Harness()
        stubHappyPath()
        server.on("GET /v1/sdk/config", .fixture("config_response_existing_users"))
    }

    override func tearDown() {
        h.cleanUp()
        super.tearDown()
    }

    private var installBody: [String: Any] { server.requests("POST /v1/sdk/install").first?.json ?? [:] }

    private func options(existingUser: Bool = false, debugDate: Date? = nil, pasteboard: ClikgateOptions.PasteboardMode = .automatic) -> ClikgateOptions {
        ClikgateOptions(linkDomains: ["inv.myapp.com"], logLevel: .none, pasteboardMode: pasteboard,
                        existingUser: existingUser, debugPlatformInstalledAt: debugDate)
    }

    // MARK: - EX.3

    func testTheFirstInstallSendsTheChannelAndTheContainerDateRoundedToTheHour() async {
        h.installFacts.createdAt = installedAt
        let core = h.makeCore()
        await core.start(startTimers: false)
        let b = installBody
        XCTAssertEqual(b["install_channel"] as? String, "app_store")
        XCTAssertEqual(b["platform_installed_source"] as? String, "ios_container_created")
        let at = ISO8601.parse(b["platform_installed_at"] as? String)
        XCTAssertEqual(at?.timeIntervalSince1970, 1_740_906_000)
        XCTAssertNotNil(b["device_time"])
        XCTAssertNil(b["existing_user_hint"])
        XCTAssertNil(b["installed_before_start"])
        XCTAssertNil(b["keychain_restored_from_other_device"])
    }

    func testWithoutAReadableDateOnlyTheChannelIsSent() async {
        h.installFacts.channelValue = "testflight"
        let core = h.makeCore()
        await core.start(startTimers: false)
        XCTAssertEqual(installBody["install_channel"] as? String, "testflight")
        XCTAssertNil(installBody["platform_installed_at"])
    }

    func testTheDebugDateCountsOnlyInXcodeBuildsWithATestKey() async {
        var c = Fixtures.json("config_response_existing_users")
        c["environment"] = "sandbox"
        server.on("GET /v1/sdk/config", StubResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: c)))
        h.installFacts.channelValue = "xcode"
        h.installFacts.createdAt = installedAt
        let debug = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
        let core = h.makeCore(options: options(debugDate: debug))
        await core.start(startTimers: false)
        XCTAssertEqual(ISO8601.parse(installBody["platform_installed_at"] as? String)?.timeIntervalSince1970, 1_699_999_200)
    }

    func testTheDebugDateIsIgnoredInAppStoreBuilds() async {
        h.installFacts.createdAt = installedAt
        let core = h.makeCore(options: options(debugDate: Date(timeIntervalSince1970: 1_700_000_000)))
        await core.start(startTimers: false)
        XCTAssertEqual(ISO8601.parse(installBody["platform_installed_at"] as? String)?.timeIntervalSince1970, 1_740_906_000)
    }

    // MARK: - R.3

    func testOptedOutSendsOnlyWhetherTheAppWasHereBeforeTheStartDate() {
        let start = ISO8601.parse("2026-11-01T08:00:00Z")
        let o = ExistingUserFields.build(channel: "app_store", installedAt: installedAt, hint: false, restored: false,
                                         datesAllowed: false, startAt: start, now: Date())
        XCTAssertEqual(Set(o.keys), ["install_channel", "existing_user_hint", "installed_before_start"])
        XCTAssertEqual(o["installed_before_start"] as? Bool, true)
        let none = ExistingUserFields.build(channel: "app_store", installedAt: installedAt, hint: true, restored: false,
                                            datesAllowed: false, startAt: nil, now: Date())
        XCTAssertNil(none["installed_before_start"])
        XCTAssertEqual(none["existing_user_hint"] as? Bool, true)
    }

    func testTheOptedOutFirstInstallCarriesNoDates() async {
        h.installFacts.createdAt = installedAt
        let core = h.makeCore()
        await core.setTrackingEnabled(false)
        await core.start(startTimers: false)
        let b = installBody
        XCTAssertNotNil(b["install_channel"])
        XCTAssertNil(b["platform_installed_at"])
        XCTAssertNil(b["device_time"])
    }

    // MARK: - R.1

    func testOnlyTheRestoredKeychainItemMeansAnotherPhone() async {
        h = Harness(keychain: "0f6b8a2c-3d4e-4f5a-8b6c-7d8e9f0a1b2c")
        stubHappyPath()
        h.keychain.marker = nil // an iCloud restore / Quick Start: the this-device-only item didn't come back
        let core = h.makeCore()
        await core.start(startTimers: false)
        XCTAssertEqual(installBody["keychain_previous_installation_id"] as? String, "0f6b8a2c-3d4e-4f5a-8b6c-7d8e9f0a1b2c")
        XCTAssertEqual(installBody["keychain_restored_from_other_device"] as? Bool, true)
        XCTAssertEqual(h.keychain.marker, h.keychain.value, "the marker is written for this phone")
    }

    func testAReinstallOnTheSamePhoneIsNotFlagged() async {
        h = Harness(keychain: "0f6b8a2c-3d4e-4f5a-8b6c-7d8e9f0a1b2c")
        stubHappyPath()
        let core = h.makeCore()
        await core.start(startTimers: false)
        XCTAssertNotNil(installBody["keychain_previous_installation_id"])
        XCTAssertNil(installBody["keychain_restored_from_other_device"])
    }

    // MARK: - R.23

    func testTheHintWithoutADateSkipsThePasteboardAndAdServices() async {
        server.on("GET /v1/sdk/config", .fixture("config_response"))
        h.pasteboard.detect = true
        h.pasteboard.text = "https://inv.myapp.com/x?cgdl=cgdl_9Xk2abcdefghijklmnopqrstuv"
        h.searchAdsToken = "aaa"
        let core = h.makeCore(options: options(existingUser: true))
        await core.start(startTimers: false)
        XCTAssertEqual(installBody["existing_user_hint"] as? Bool, true)
        XCTAssertEqual(h.pasteboard.reads, 0)
        XCTAssertNil(installBody["apple_search_ads_token"])
    }

    func testTheHintWithADateKeepsThePasteboard() async {
        server.on("GET /v1/sdk/config", .fixture("config_response"))
        h.installFacts.createdAt = installedAt
        h.pasteboard.detect = true
        h.pasteboard.text = "nothing here"
        let core = h.makeCore(options: options(existingUser: true))
        await core.start(startTimers: false)
        XCTAssertEqual(h.pasteboard.reads, 1)
    }

    // MARK: - KC.6

    func testAppleRecordIsSentOnceAfterTheInstall() async {
        server.on("POST /v1/sdk/app-record", .fixture("app_record_response"))
        h.installFacts.record = Fixtures.json("app_record_request")["signed_record"] as? String
        let core = h.makeCore()
        await core.start(startTimers: false)
        let sent = server.requests("POST /v1/sdk/app-record")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.json["signed_record"] as? String, h.installFacts.record)
        XCTAssertNotNil(sent.first?.json["installation_id"])
        await core.sendAppRecordIfNeeded()
        XCTAssertEqual(server.requests("POST /v1/sdk/app-record").count, 1)
    }

    func testAppleRecordIsTriedTwiceThenNeverAgain() async {
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.sendAppRecordIfNeeded()
        await core.sendAppRecordIfNeeded()
        XCTAssertEqual(h.installFacts.recordCalls, 2)
        XCTAssertEqual(server.requests("POST /v1/sdk/app-record").count, 0)
    }

    func testNoAppleRecordWhileReferralsAreOff() async {
        var c = Fixtures.json("config_response_existing_users")
        var f = c["features"] as! [String: Any]
        f["referrals"] = false
        c["features"] = f
        server.on("GET /v1/sdk/config", StubResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: c)))
        h.installFacts.record = "x"
        let core = h.makeCore()
        await core.start(startTimers: false)
        XCTAssertEqual(h.installFacts.recordCalls, 0)
    }

    // MARK: - RF.1 and the install answer

    func testApplyCodeFromAnExistingUserIsTheExistingUserError() async {
        server.on("POST /v1/sdk/referrals/apply-code", .fixture("error_existing_user", status: 409))
        let core = h.makeCore()
        await core.start(startTimers: false)
        do {
            let body = try JSONSerialization.data(withJSONObject: ["program_id": "rpg_01JAB3C4D5E6F7G8H9JKMNPQRS", "code": "ADA42"])
            _ = try await core.referralCall({ ClikgateReferredBy(json: $0) }, method: "POST", path: "v1/sdk/referrals/apply-code",
                                            body: body)
            XCTFail("expected an error")
        } catch let e as ClikgateError {
            XCTAssertTrue(e.isExistingUser)
            XCTAssertEqual(e.code, ClikgateError.existingUser)
            XCTAssertEqual(e.status, 409)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testAnExistingUserInstallIsOrganicWithTheFlag() async {
        server.on("POST /v1/sdk/install", .fixture("install_response_existing_user"))
        let core = h.makeCore()
        await core.start(startTimers: false)
        let a = await core.attribution(timeout: 1)
        XCTAssertEqual(a.status, .organic)
        XCTAssertTrue(a.isExistingUser)
        // Kept across launches
        let st = await core.currentState()
        XCTAssertEqual(st.attribution?.isExistingUser, true)
    }

    // MARK: - R.11

    func testTheWaitInTheErrorBodyIsHonouredWithJitter() async {
        server.on("POST /v1/sdk/install", .fixture("error_rate_limited_retry_after", status: 429), .fixture("install_response_organic"))
        let core = h.makeCore()
        await core.start(startTimers: false)
        XCTAssertTrue(h.clock.sleeps.contains { $0 >= 30 && $0 <= 37.5 }, "\(h.clock.sleeps)")
    }

    // MARK: - R.28

    func testSavedLinksBelongToTheSignedInCustomer() async {
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.identifyUser(label: nil, customerId: "user_42", identityToken: nil)
        let (none, token) = core.links.link("rpg_1")
        XCTAssertNil(none)
        XCTAssertNotNil(token)
        core.links.save("rpg_1", Fixtures.data("referral_link_response"), token: token)
        XCTAssertNotNil(core.links.link("rpg_1").0)
        let file = try? String(contentsOf: h.dir.appendingPathComponent("links.json"), encoding: .utf8)
        XCTAssertFalse(file?.contains("user_42") ?? true, "never the customer ID in clear")

        // Another customer: nothing saved, and an answer started for the previous one is dropped
        await core.identifyUser(label: nil, customerId: "user_77", identityToken: nil)
        XCTAssertNil(core.links.link("rpg_1").0)
        core.links.save("rpg_1", Fixtures.data("referral_link_response"), token: token)
        XCTAssertNil(core.links.link("rpg_1").0)

        // Sign-out clears
        let token2 = core.links.link("rpg_1").1
        core.links.save("rpg_1", Fixtures.data("referral_link_response"), token: token2)
        XCTAssertNotNil(core.links.link("rpg_1").0)
        await core.identifyUser(label: nil, customerId: nil, identityToken: nil)
        XCTAssertNil(core.links.link("rpg_1").0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.dir.appendingPathComponent("links.json").path))
    }

    func testIdentifyAsksEngageToPrepareTheProgramsLinks() async {
        let core = h.makeCore()
        await core.start(startTimers: false)
        let got = Programs()
        core.links.setListener { got.set($0) }
        await core.identifyUser(label: nil, customerId: "user_42", identityToken: nil)
        await eventually { got.value == ["rpg_01JAB3C4D5E6F7G8H9JKMNPQRS"] }
    }
}

private final class Programs: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: [String] = []
    func set(_ v: [String]) { lock.lock(); _v = v; lock.unlock() }
    var value: [String] { lock.lock(); defer { lock.unlock() }; return _v }
}
