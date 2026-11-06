import XCTest
@testable import Clikgate

/// Change 19 (R.20 S.1, S.2): the AdServices token is requested when /install is actually sent (also after consent
/// buffering), again after 24 hours, never kept on the device; IDFV goes with it for Redownload linking; LinkedIn
/// `li_fat_id` and Snap `ScCid` reach the server in the launch / resolved URL.
final class Change19Tests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared

    override func setUp() {
        super.setUp()
        server.reset()
        h = Harness()
        stubHappyPath()
        server.on("POST /v1/sdk/consent", .ok)
        server.on("POST /v1/sdk/install-ping", .ok)
    }

    override func tearDown() {
        h.cleanUp()
        super.tearDown()
    }

    private func stubConfig(_ name: String = "config_response", appleAds: Bool = true) {
        var c = Fixtures.json(name)
        var f = c["features"] as! [String: Any]
        f["apple_search_ads"] = appleAds
        c["features"] = f
        server.on("GET /v1/sdk/config", StubResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: c)))
    }

    private func installs() -> [[String: Any]] { server.requests("POST /v1/sdk/install").map { $0.json } }

    /// Nothing under the SDK's storage directory contains the token.
    private func assertNotOnDisk(_ token: String, file: StaticString = #filePath, line: UInt = #line) {
        let files = FileManager.default.enumerator(at: h.dir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for f in files {
            let text = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            XCTAssertFalse(text.contains(token), "\(f.lastPathComponent) keeps the AdServices token", file: file, line: line)
        }
    }

    func testTokenRequestedWhenTheInstallIsSentAndNotKept() async throws {
        stubConfig()
        h.searchAdsToken = "asa-token-1"
        let core = h.makeCore()
        await core.start(startTimers: false)
        let install = try XCTUnwrap(installs().first)
        XCTAssertEqual(install["apple_search_ads_token"] as? String, "asa-token-1")
        XCTAssertEqual(install["idfv"] as? String, "6F9619FF-8B86-D011-B42D-00C04FC964FF", "IDFV links a Redownload")
        XCTAssertEqual(h.searchAds.calls, 1)
        assertNotOnDisk("asa-token-1")

        // Next launch: no new install, no AdServices call
        let next = h.makeCore()
        await next.start(startTimers: false)
        XCTAssertEqual(installs().count, 1)
        XCTAssertEqual(h.searchAds.calls, 1)
    }

    func testOffWhenTheSettingIsOff() async throws {
        stubConfig(appleAds: false)
        h.searchAdsToken = "asa-token-1"
        let core = h.makeCore()
        await core.start(startTimers: false)
        let install = try XCTUnwrap(installs().first)
        XCTAssertNil(install["apple_search_ads_token"])
        XCTAssertNil(install["idfv"], "without identity checks, App Attest or Apple Ads no IDFV")
        XCTAssertEqual(h.searchAds.calls, 0)
    }

    func testConsentBufferingRequestsTheTokenOnlyAtGrant() async throws {
        stubConfig("config_response_consent_required")
        h.searchAdsToken = "asa-token-1"
        let core = h.makeCore()
        await core.start(startTimers: false)
        XCTAssertTrue(installs().isEmpty)
        XCTAssertEqual(h.searchAds.calls, 0, "no AdServices call while consent is unknown")

        h.clock.advance(3 * 86_400)   // granted three days later: a token from first launch would have expired
        h.searchAds.tokens = ["asa-token-fresh"]
        await core.setConsent(analytics: .granted, attribution: .granted, adUserData: nil, adPersonalization: nil)
        await drainMain()
        let install = try XCTUnwrap(installs().first)
        XCTAssertEqual(install["apple_search_ads_token"] as? String, "asa-token-fresh")
        XCTAssertEqual(h.searchAds.calls, 1)
        assertNotOnDisk("asa-token-fresh")
    }

    func testAttributionDeniedInARequiredRegionNeverCallsAdServices() async throws {
        stubConfig("config_response_consent_required")
        h.searchAdsToken = "asa-token-1"
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.setConsent(analytics: .denied, attribution: .denied, adUserData: .denied, adPersonalization: .denied)
        XCTAssertTrue(installs().isEmpty)
        XCTAssertEqual(h.searchAds.calls, 0)
        XCTAssertNil(server.requests("POST /v1/sdk/install-ping").first?.json["apple_search_ads_token"])
    }

    func testANewTokenAfter24HoursOfRetries() async throws {
        stubConfig()
        h.searchAds.tokens = ["asa-token-1", "asa-token-2"]
        // The first attempt fails and the server asks to wait 25 hours; the retry needs a new token (valid 24 h)
        server.on("POST /v1/sdk/install",
                  StubResponse(status: 503, body: Data(#"{"error":{"code":"unavailable","message":"x"}}"#.utf8), headers: ["Retry-After": "90000"]),
                  .fixture("install_response_organic"))
        let core = h.makeCore()
        await core.start(startTimers: false)
        let sent = installs().map { $0["apple_search_ads_token"] as? String }
        XCTAssertEqual(sent, ["asa-token-1", "asa-token-2"])
        XCTAssertEqual(h.searchAds.calls, 2)
    }

    func testAShortRetryReusesTheToken() async throws {
        stubConfig()
        h.searchAds.tokens = ["asa-token-1", "asa-token-2"]
        server.on("POST /v1/sdk/install",
                  StubResponse(status: 503, body: Data(#"{"error":{"code":"unavailable","message":"x"}}"#.utf8), headers: ["Retry-After": "5"]),
                  .fixture("install_response_organic"))
        let core = h.makeCore()
        await core.start(startTimers: false)
        XCTAssertEqual(installs().map { $0["apple_search_ads_token"] as? String }, ["asa-token-1", "asa-token-1"])
        XCTAssertEqual(h.searchAds.calls, 1)
    }

    // MARK: - S.2: LinkedIn and Snap click ids travel in the Clikgate URLs the server reads

    func testLinkedInAndSnapClickIdsReachTheServer() async throws {
        let core = h.makeCore()
        let launch = "https://inv.myapp.com/p/dress?cg_click_id=clk_1&li_fat_id=0f1e2d3c-aaaa-bbbb-cccc-1234567890ab&ScCid=snapclick123"
        await core.resolve(url: URL(string: launch)!)   // the launch URL
        await core.start(startTimers: false)
        let install = try XCTUnwrap(installs().first)
        XCTAssertEqual(install["launch_url"] as? String, launch, "kept as opened: ScCid keeps its case")

        let opened = "https://inv.myapp.com/p/shoes?li_fat_id=LIFAT2&ScCid=SNAP2"
        await core.resolve(url: URL(string: opened)!)
        XCTAssertEqual(server.requests("POST /v1/sdk/resolve").last?.json["url"] as? String, opened)
    }

    func testLinkedInAndSnapClickIdsKeptThroughConsentBuffering() async throws {
        stubConfig("config_response_consent_required", appleAds: false)
        let core = h.makeCore()
        await core.start(startTimers: false)
        let launch = "https://inv.myapp.com/p/dress?cg_click_id=clk_1&li_fat_id=LIFAT1&ScCid=SNAP1"
        await core.resolve(url: URL(string: launch)!)
        await core.resolve(url: URL(string: "https://inv.myapp.com/p/shoes?ScCid=SNAP2")!)
        XCTAssertTrue(installs().isEmpty)
        await core.setConsent(analytics: nil, attribution: .granted, adUserData: nil, adPersonalization: nil)
        await drainMain()
        XCTAssertEqual(installs().first?["launch_url"] as? String, launch)
        XCTAssertEqual(server.requests("POST /v1/sdk/resolve").first?.json["url"] as? String, "https://inv.myapp.com/p/shoes?ScCid=SNAP2")
    }
}
