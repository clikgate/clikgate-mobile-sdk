import XCTest
@testable import Clikgate

final class LifecycleTests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared

    override func setUp() {
        super.setUp()
        server.reset()
        h = Harness()
    }

    override func tearDown() {
        h.cleanUp()
        super.tearDown()
    }

    func testFirstLaunchCreatesInstallationIdInStateAndKeychainAndSendsInstall() async throws {
        stubHappyPath()
        let core = h.makeCore()
        await core.start(startTimers: false)

        let state = await core.currentState()
        let id = try XCTUnwrap(state.installationId)
        XCTAssertEqual(h.keychain.value, id)
        XCTAssertEqual(state.installId, "ins_01JAB3C4D5E6F7G8H9JKMNPQRS")

        let installs = server.requests("POST /v1/sdk/install")
        XCTAssertEqual(installs.count, 1)
        let body = installs[0].json
        XCTAssertEqual(body["installation_id"] as? String, id)
        XCTAssertNil(body["keychain_previous_installation_id"] as? String)
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertNil((body["consent"] as? [String: Any])?["tracking_allowed"], "no tracking_allowed from 1.5.0 (X.E23)")
        XCTAssertEqual((body["consent"] as? [String: Any])?["attribution"] as? String, "unknown")
        XCTAssertEqual(installs[0].headers["Clikgate-Installation-Id"], id)
        XCTAssertEqual(installs[0].headers["Clikgate-SDK-Key"], "cg_sdk_test")
        XCTAssertEqual(installs[0].headers["Clikgate-SDK-Version"], "ios/\(Clikgate.sdkVersion)")
        XCTAssertNil(installs[0].headers["Clikgate-SDK-Native-Version"])
        XCTAssertTrue(server.requests("POST /v1/sdk/open").isEmpty, "first launch must not send /open")
    }

    func testInstallRequestOnlyUsesFieldsFromTheIOSFixture() async throws {
        stubHappyPath()
        let core = h.makeCore()
        await core.start(startTimers: false)
        let sent = Set(try XCTUnwrap(server.requests("POST /v1/sdk/install").first).json.keys)
        let fixtureKeys = Set(Fixtures.json("install_request_ios").keys)
        let schemaOnlyOptional: Set<String> = ["attestation", "apple_search_ads_token"]
        XCTAssertTrue(sent.isSubset(of: fixtureKeys.union(schemaOnlyOptional)), "unexpected keys: \(sent.subtracting(fixtureKeys))")
        XCTAssertTrue(["installation_id", "app_version", "sdk_version", "platform"].allSatisfy(sent.contains))
    }

    func testReinstallSendsPreviousKeychainIdAndCreatesNewOne() async throws {
        let old = "b8c2d4e6-1a3c-4e5f-8a7b-9c0d1e2f3a4b"
        h = Harness(keychain: old)
        stubHappyPath()
        let core = h.makeCore()
        await core.start(startTimers: false)
        let state = await core.currentState()
        XCTAssertNotEqual(state.installationId, old)
        XCTAssertEqual(h.keychain.value, state.installationId)
        let body = try XCTUnwrap(server.requests("POST /v1/sdk/install").first).json
        XCTAssertEqual(body["keychain_previous_installation_id"] as? String, old)
        XCTAssertNil(state.keychainPreviousInstallationId, "cleared after a successful install")
    }

    func testLaterLaunchSendsColdOpenNotInstall() async throws {
        stubHappyPath()
        let first = h.makeCore()
        await first.start(startTimers: false)
        server.reset()
        stubHappyPath()

        let second = h.makeCore()   // same storage directory = next launch
        await second.start(startTimers: false)
        XCTAssertTrue(server.requests("POST /v1/sdk/install").isEmpty)
        let opens = server.requests("POST /v1/sdk/open")
        XCTAssertEqual(opens.count, 1)
        XCTAssertEqual(opens[0].json["is_cold_start"] as? Bool, true)
        XCTAssertTrue(server.requests("GET /v1/sdk/config").isEmpty, "config cached for 1 h")
    }

    func testForegroundAfterSessionTimeoutSendsWarmOpen() async throws {
        stubHappyPath()
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.appDidEnterBackground()
        h.clock.advance(10 * 60)
        await core.appWillEnterForeground(startTimers: false)
        XCTAssertTrue(server.requests("POST /v1/sdk/open").isEmpty, "10 min < 30 min session timeout")

        await core.appDidEnterBackground()
        h.clock.advance(31 * 60)
        await core.appWillEnterForeground(startTimers: false)
        let opens = server.requests("POST /v1/sdk/open")
        XCTAssertEqual(opens.count, 1)
        XCTAssertEqual(opens[0].json["is_cold_start"] as? Bool, false)
    }

    func testInstallRetriesUntilItSucceeds() async throws {
        stubHappyPath()
        server.on("POST /v1/sdk/install", .offline(), .json("{}", status: 503), .fixture("install_response_organic"))
        let core = h.makeCore()
        await core.start(startTimers: false)
        XCTAssertEqual(server.requests("POST /v1/sdk/install").count, 3)
        let state = await core.currentState()
        XCTAssertTrue(state.installDone)
        XCTAssertEqual(Array(h.clock.sleeps.prefix(2)), [1, 2], "exponential backoff 1 s, 2 s")
        let ids = Set(server.requests("POST /v1/sdk/install").map { $0.json["installation_id"] as? String })
        XCTAssertEqual(ids.count, 1, "same installation id on every retry")
    }

    func testRateLimitHonoursRetryAfter() async throws {
        stubHappyPath()
        server.on("POST /v1/sdk/install", .fixture("error_rate_limited", status: 429, headers: ["Retry-After": "7"]),
                  .fixture("install_response_organic"))
        let core = h.makeCore()
        await core.start(startTimers: false)
        XCTAssertEqual(h.clock.sleeps.first, 7)
        let done = await core.currentState().installDone
        XCTAssertTrue(done)
    }

    func testInvalidSdkKeyStopsAllCalls() async throws {
        stubHappyPath()
        server.on("GET /v1/sdk/config", .json(#"{"error":{"type":"auth","code":"invalid_sdk_key","message":"bad"}}"#, status: 401))
        server.on("POST /v1/sdk/install", .json(#"{"error":{"type":"auth","code":"invalid_sdk_key","message":"bad"}}"#, status: 401))
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.goal("signup", value: nil, currency: nil, reference: nil, isFirst: nil)
        await core.flush()
        let keys = server.requests.map { $0.key }
        XCTAssertEqual(keys, ["GET /v1/sdk/config"], "after a 401 nothing else is sent this launch")
    }

    func testConfigFixtureDecodes() throws {
        let c = RemoteConfig(json: Fixtures.json("config_response"))
        XCTAssertEqual(c.linkDomains, ["inv.myapp.com", "ciz.to"])
        XCTAssertEqual(c.features.pasteboardMatching, "on_interstitial_tap")
        XCTAssertEqual(c.features.iosAppAttest, "off")
        XCTAssertEqual(c.batching.flushAtCount, 20)
        XCTAssertEqual(c.sessionTimeoutMinutes, 30)
    }

    func testConfigFailureFallsBackToDefaults() async throws {
        stubHappyPath()
        server.on("GET /v1/sdk/config", .offline())
        let core = h.makeCore()
        await core.start(startTimers: false)
        let config = await core.config
        XCTAssertEqual(config.features.pasteboardMatching, "off")
        XCTAssertEqual(h.pasteboard.detections, 0, "pasteboard matching is off by default")
        let done = await core.currentState().installDone
        XCTAssertTrue(done)
    }

    func testWrapperHeaders() async throws {
        stubHappyPath()
        let core = h.makeCore(wrapper: WrapperInfo(name: "flutter", version: "1.2.0"))
        await core.start(startTimers: false)
        let r = try XCTUnwrap(server.requests("POST /v1/sdk/install").first)
        XCTAssertEqual(r.headers["Clikgate-SDK-Version"], "flutter/1.2.0")
        XCTAssertEqual(r.headers["Clikgate-SDK-Native-Version"], "ios/\(Clikgate.sdkVersion)")
    }

    func testWaitForATTPollsUntilDetermined() async throws {
        h = Harness(tracking: FakeTracking(undeterminedFor: 3))
        stubHappyPath()
        var options = ClikgateOptions(linkDomains: [], logLevel: .none)
        options.waitForATT = true
        let core = h.makeCore(options: options)
        await core.start(startTimers: false)
        XCTAssertEqual(h.tracking.notDeterminedChecks, 4)
        XCTAssertEqual(h.clock.sleeps.filter { $0 == 0.5 }.count, 3)
    }

    func testAppleSearchAdsTokenSentWhenEnabled() async throws {
        h.searchAdsToken = "asa-token"
        stubHappyPath()
        var config = Fixtures.json("config_response")
        var features = config["features"] as! [String: Any]
        features["apple_search_ads"] = true
        config["features"] = features
        server.on("GET /v1/sdk/config", StubResponse(status: 200, body: try JSONSerialization.data(withJSONObject: config)))
        let core = h.makeCore()
        await core.start(startTimers: false)
        XCTAssertEqual(server.requests("POST /v1/sdk/install").first?.json["apple_search_ads_token"] as? String, "asa-token")
    }

    func testAppAttestIncludedInInstallWhenEnabled() async throws {
        h = Harness(attest: FakeAppAttest(supported: true))
        stubHappyPath()
        var config = Fixtures.json("config_response")
        var features = config["features"] as! [String: Any]
        features["attestation"] = ["ios_app_attest": "monitor", "android_play_integrity": "off"]
        config["features"] = features
        server.on("GET /v1/sdk/config", StubResponse(status: 200, body: try JSONSerialization.data(withJSONObject: config)))
        // 32 zero bytes, base64url
        server.on("POST /v1/sdk/attest/challenge", .json(#"{"challenge":"atc_1","nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expires_at":"2026-10-20T10:05:00Z"}"#))
        var options = ClikgateOptions(linkDomains: [], logLevel: .none)
        options.attestation = .appAttestIfAvailable
        let core = h.makeCore(options: options)
        await core.start(startTimers: false)
        let att = try XCTUnwrap(server.requests("POST /v1/sdk/install").first?.json["attestation"] as? [String: Any])
        XCTAssertEqual(att["type"] as? String, "app_attest")
        XCTAssertEqual(att["challenge"] as? String, "atc_1")
        XCTAssertEqual(att["key_id"] as? String, "a2V5LWlk")
        XCTAssertEqual(att["token"] as? String, Data("attestation".utf8).base64EncodedString())
        XCTAssertEqual(h.attest.hashes.first, ClikgateCore.clientDataHash(nonce: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertEqual(h.attest.hashes.first?.count, 32)

        // Re-attestation after the interval uses an assertion for the same key.
        server.on("POST /v1/sdk/attest", .json(#"{"attestation_status":"valid"}"#))
        h.clock.advance(8 * 86_400)
        await core.reattestIfDue()
        let attest = try XCTUnwrap(server.requests("POST /v1/sdk/attest").first?.json)
        XCTAssertEqual(attest["type"] as? String, "app_attest_assertion")
        XCTAssertEqual(attest["key_id"] as? String, "a2V5LWlk")
        XCTAssertEqual(h.attest.assertions, 1)
        XCTAssertEqual(h.attest.generated, 1)
    }

    func testExpiredChallengeIsNotResentOnLateInstallRetries() async throws {
        h = Harness(attest: FakeAppAttest(supported: true))
        stubHappyPath()
        var config = Fixtures.json("config_response")
        var features = config["features"] as! [String: Any]
        features["attestation"] = ["ios_app_attest": "monitor", "android_play_integrity": "off"]
        config["features"] = features
        server.on("GET /v1/sdk/config", StubResponse(status: 200, body: try JSONSerialization.data(withJSONObject: config)))
        server.on("POST /v1/sdk/attest/challenge", .json(#"{"challenge":"atc_1","nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expires_at":"2026-10-20T10:05:00Z"}"#))
        server.on("POST /v1/sdk/attest", .json(#"{"attestation_status":"valid"}"#))
        let offline = Array(repeating: StubResponse.offline(), count: 10)
        server.on("POST /v1/sdk/install", .offline(), .offline(), .offline(), .offline(), .offline(),
                  .offline(), .offline(), .offline(), .offline(), .offline(), .fixture("install_response_organic"))
        _ = offline
        var options = ClikgateOptions(linkDomains: [], logLevel: .none)
        options.attestation = .appAttestIfAvailable
        let core = h.makeCore(options: options)
        await core.start(startTimers: false)
        let installs = server.requests("POST /v1/sdk/install")
        XCTAssertEqual(installs.count, 11)
        XCTAssertNotNil(installs.first?.json["attestation"])
        XCTAssertNil(installs.last?.json["attestation"], "challenge older than 5 minutes is not reused")
        let attest = try XCTUnwrap(server.requests("POST /v1/sdk/attest").first?.json)
        XCTAssertEqual(attest["type"] as? String, "app_attest", "key never accepted: full attestation via /attest")
        XCTAssertEqual(server.requests("POST /v1/sdk/attest/challenge").count, 2, "a new single-use challenge")
    }

    func testApnsEnvironmentParsedFromProvisioningProfile() {
        func profile(_ env: String?) -> Data {
            let ent = env.map { "<key>aps-environment</key><string>\($0)</string>" } ?? ""
            let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>Entitlements</key><dict>\(ent)</dict></dict></plist>"
            return Data([0x30, 0x82, 0x01]) + Data(xml.utf8) + Data([0x00, 0xA0])
        }
        XCTAssertEqual(ProvisioningProfile.parseApsEnvironment(profileData: profile("development")), "sandbox")
        XCTAssertEqual(ProvisioningProfile.parseApsEnvironment(profileData: profile("production")), "production")
        XCTAssertEqual(ProvisioningProfile.parseApsEnvironment(profileData: profile(nil)), "production")
        XCTAssertEqual(ProvisioningProfile.parseApsEnvironment(profileData: Data()), "production")
    }
}
