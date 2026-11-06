import XCTest
@_spi(ClikgateWrapper) @testable import Clikgate

/// Change 03 (SDK 1.2.0): consent, buffering, click ids, version policy, Firebase forwarding,
/// attribution metadata, clipboard opt-in, identity checks and Google on-device measurement.
final class Change03Tests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared
    let token = "cgdl_9Xk2abcdefghijklmnopqrstuv"

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

    private func stubConfig(_ name: String = "config_response", _ mutate: (inout [String: Any]) -> Void = { _ in }) {
        var c = Fixtures.json(name)
        mutate(&c)
        server.on("GET /v1/sdk/config", StubResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: c)))
    }

    private func features(_ c: inout [String: Any], _ f: (inout [String: Any]) -> Void) {
        var x = c["features"] as! [String: Any]
        f(&x)
        c["features"] = x
    }

    private func identifying() -> [RecordedRequest] { server.requests.filter { $0.path != "/v1/sdk/config" } }

    private func assertConsent(_ r: RecordedRequest?, attribution: String, file: StaticString = #filePath, line: UInt = #line) {
        let c = r?.json["consent"] as? [String: Any]
        XCTAssertNotNil(c, "consent missing on \(r?.key ?? "nil")", file: file, line: line)
        XCTAssertEqual(c?["attribution"] as? String, attribution, file: file, line: line)
        for k in ["analytics", "ad_user_data", "ad_personalization"] { XCTAssertNotNil(c?[k] as? String, k, file: file, line: line) }
        XCTAssertTrue(c?.keys.contains("region") ?? false, file: file, line: line)
        XCTAssertTrue(c?.keys.contains("updated_at") ?? false, file: file, line: line)
    }

    // MARK: - Regions

    func testRegionNormalisationAndMatching() {
        XCTAssertEqual(ConsentRegions.normalize(" de "), "DE")
        XCTAssertEqual(ConsentRegions.normalize("eea"), "EEA")
        XCTAssertEqual(ConsentRegions.normalize("UK"), "UK")
        XCTAssertNil(ConsentRegions.normalize("GBR"))
        XCTAssertNil(ConsentRegions.normalize("E1"))
        XCTAssertNil(ConsentRegions.normalize(""))
        XCTAssertEqual(ConsentRegions.eea.count, 30)
        let regions = ConsentRegions.defaultRequired
        for hint in ["DE", "FR", "NO", "IS", "LI", "EEA", "UK", "GB", "CH"] { XCTAssertTrue(ConsentRegions.matches(hint, regions), hint) }
        for hint in ["NG", "US", "KE"] { XCTAssertFalse(ConsentRegions.matches(hint, regions), hint) }
        XCTAssertTrue(ConsentRegions.matches("NG", ["NG"]))
    }

    func testRequiredFromModeHintAndDefaults() async {
        // No config: only the hint decides (default regions), nil without one.
        var core = h.makeCore()
        var r = await core.consentRequired
        XCTAssertNil(r)
        await core.setConsentRegion("DE")
        r = await core.consentRequired
        XCTAssertEqual(r, true)
        h.cleanUp()

        // Config says not required for NG, but a hint inside required_regions wins.
        h = Harness()
        stubConfig()
        core = h.makeCore()
        await core.start(startTimers: false)
        r = await core.consentRequired
        XCTAssertEqual(r, false)
        await core.setConsentRegion("FR")
        r = await core.consentRequired
        XCTAssertEqual(r, true)
        XCTAssertEqual(core.snapshot.consent.isRequired, true)
        XCTAssertEqual(core.snapshot.consent.region, "FR")
    }

    // MARK: - Consent on every body

    func testConsentTravelsOnEveryRequestBody() async throws {
        h.firebase = FakeFirebase(available: false)
        let core = h.makeCore()
        await core.setConsent(analytics: .granted, attribution: .granted, adUserData: .denied, adPersonalization: nil)
        await core.setPushToken("a1b2c3d4", provider: "apns")
        await core.start(startTimers: false)
        await core.identifyUser(label: nil, customerId: "user_42", identityToken: nil)
        await core.setPushToken("ffff", provider: "apns")
        await core.track(name: "purchase", revenue: nil, properties: nil)
        await core.flush()
        await core.resolve(url: URL(string: "https://inv.myapp.com/p/dress")!)
        await core.sendOpen(coldStart: true)

        for key in ["POST /v1/sdk/install", "POST /v1/sdk/events", "POST /v1/sdk/identify", "POST /v1/sdk/push-token",
                    "POST /v1/sdk/resolve", "POST /v1/sdk/open", "POST /v1/sdk/consent"] {
            assertConsent(server.requests(key).first, attribution: "granted")
        }
        let install = try XCTUnwrap(server.requests("POST /v1/sdk/install").first).json["consent"] as? [String: Any]
        XCTAssertNil(install?["tracking_allowed"], "no tracking_allowed from 1.5.0 (X.E23)")
        XCTAssertEqual(install?["ad_user_data"] as? String, "denied")
        XCTAssertEqual(install?["ad_personalization"] as? String, "unknown")
        XCTAssertNotNil(install?["updated_at"] as? String)
        // Config carries the installation id when not buffering.
        XCTAssertNotNil(server.requests("GET /v1/sdk/config").first?.headers["Clikgate-Installation-Id"])
    }

    // MARK: - Buffering

    func testUnknownConsentBuffersAndGrantFlushes() async throws {
        stubConfig("config_response_consent_required")
        let core = h.makeCore()
        let box = collect(h.dispatcher)
        await core.start(startTimers: false)
        await core.track(name: "signup", revenue: nil, properties: nil)
        await core.track(name: "purchase", revenue: ClikgateMoney.ofMinor(500, currency: "NGN"), properties: nil)
        await core.resolve(url: URL(string: "https://inv.myapp.com/p/dress?cg_click_id=clk_1")!)
        await core.resolve(url: URL(string: "https://inv.myapp.com/p/shoes")!)
        await drainMain()

        XCTAssertTrue(identifying().isEmpty, "nothing identifying while consent is unknown: \(identifying().map { $0.key })")
        // The first fetch can't know the consent mode yet; later fetches while buffering are anonymous.
        await core.refreshConfig(force: true)
        let config = try XCTUnwrap(server.requests("GET /v1/sdk/config").last)
        XCTAssertNil(config.headers["Clikgate-Installation-Id"], "config without the installation id while buffering")
        XCTAssertEqual(box.items.count, 2, "links delivered locally")
        XCTAssertEqual(box.items.first?.data["cg_click_id"] as? String, "clk_1")
        XCTAssertEqual(box.items.first?.path, "/p/dress")
        let buffered = await core.queuedEventCount
        XCTAssertEqual(buffered, 2)
        var st = await core.currentState()
        XCTAssertNotNil(st.consentPendingSince)
        XCTAssertEqual(st.launchUrl, "https://inv.myapp.com/p/dress?cg_click_id=clk_1")
        XCTAssertEqual(st.keptUrls, ["https://inv.myapp.com/p/shoes"])
        XCTAssertEqual(core.snapshot.consent.isRequired, true)
        XCTAssertTrue(core.snapshot.metadata.isEmpty)

        await core.setConsent(analytics: nil, attribution: .granted, adUserData: nil, adPersonalization: nil)
        await drainMain()
        let install = try XCTUnwrap(server.requests("POST /v1/sdk/install").first)
        XCTAssertEqual(install.json["launch_url"] as? String, "https://inv.myapp.com/p/dress?cg_click_id=clk_1")
        assertConsent(install, attribution: "granted")
        let sentEvents = server.requests("POST /v1/sdk/events").flatMap { ($0.json["events"] as? [[String: Any]]) ?? [] }
        XCTAssertEqual(sentEvents.count, 2)
        XCTAssertEqual(server.requests("POST /v1/sdk/resolve").first?.json["url"] as? String, "https://inv.myapp.com/p/shoes")
        XCTAssertEqual(server.requests("POST /v1/sdk/consent").count, 1)
        XCTAssertEqual(box.items.count, 2, "kept links are resolved silently, not delivered again")
        st = await core.currentState()
        XCTAssertNil(st.consentPendingSince)
        XCTAssertTrue(st.keptUrls.isEmpty)
    }

    func testBufferLimitAndExpiry() async throws {
        stubConfig("config_response_consent_required") { c in
            var x = c["consent"] as! [String: Any]
            x["buffer_max_events"] = 3
            c["consent"] = x
        }
        let core = h.makeCore()
        await core.start(startTimers: false)
        for i in 0..<5 { await core.track(name: "e\(i)", revenue: nil, properties: nil) }
        var names = await core.queuedEvents.map { $0.name }
        XCTAssertEqual(names, ["e2", "e3", "e4"], "oldest dropped above buffer_max_events")

        h.clock.advance(8 * 86_400)
        await core.track(name: "fresh", revenue: nil, properties: nil)
        names = await core.queuedEvents.map { $0.name }
        XCTAssertEqual(names, ["fresh"], "events older than buffer_max_days (7) expire")
        XCTAssertTrue(identifying().isEmpty)
    }

    func testDenyBeforeInstallDropsAndSendsOneAnonymousPing() async throws {
        stubConfig("config_response_consent_required")
        let core = h.makeCore(options: ClikgateOptions(linkDomains: ["inv.myapp.com"], logLevel: .none, pasteboardMode: .automatic))
        h.pasteboard.detect = true
        h.pasteboard.text = "https://inv.myapp.com/_cg/p/\(token)"
        await core.start(startTimers: false)
        await core.track(name: "signup", revenue: nil, properties: nil)
        var st = await core.currentState()
        XCTAssertEqual(st.pasteboardToken, token, "clipboard token read and kept on the device while buffering")

        await core.setConsent(analytics: .denied, attribution: .denied, adUserData: .denied, adPersonalization: .denied)
        let count = await core.queuedEventCount
        XCTAssertEqual(count, 0)
        st = await core.currentState()
        XCTAssertNil(st.pasteboardToken)
        let ping = try XCTUnwrap(server.requests("POST /v1/sdk/install-ping").first)
        XCTAssertNil(ping.headers["Clikgate-Installation-Id"])
        XCTAssertEqual(Set(ping.json.keys), ["platform", "app_version", "sdk_version", "consent"])
        assertConsent(ping, attribution: "denied")
        XCTAssertTrue(server.requests("POST /v1/sdk/install").isEmpty)
        XCTAssertTrue(server.requests("POST /v1/sdk/consent").isEmpty, "no record without an installation")

        await core.track(name: "after", revenue: nil, properties: nil)
        let after = await core.queuedEventCount
        XCTAssertEqual(after, 0, "nothing kept while denied")

        // Next launch: the ping isn't repeated.
        let next = h.makeCore()
        await next.start(startTimers: false)
        XCTAssertEqual(server.requests("POST /v1/sdk/install-ping").count, 1)
    }

    func testNoPingWithoutAnonymousCounts() async {
        stubConfig("config_response_consent_required") { c in
            var x = c["consent"] as! [String: Any]
            x["anonymous_counts"] = false
            c["consent"] = x
        }
        let core = h.makeCore()
        await core.setConsent(analytics: nil, attribution: .denied, adUserData: nil, adPersonalization: nil)
        await core.start(startTimers: false)
        XCTAssertTrue(identifying().isEmpty)
    }

    func testWithdrawalAfterInstallSendsOnlyTheConsentRecord() async throws {
        stubConfig("config_response_consent_required")
        let core = h.makeCore()
        await core.setConsent(analytics: .granted, attribution: .granted, adUserData: .granted, adPersonalization: .granted)
        await core.start(startTimers: false)
        XCTAssertEqual(server.requests("POST /v1/sdk/install").count, 1)
        server.reset(); stubHappyPath(); server.on("POST /v1/sdk/consent", .ok)

        await core.setConsent(analytics: nil, attribution: .denied, adUserData: nil, adPersonalization: nil)
        await core.track(name: "purchase", revenue: nil, properties: nil)
        await core.flush()
        await core.sendOpen(coldStart: false)
        XCTAssertEqual(server.requests.map { $0.key }, ["POST /v1/sdk/consent"])
        assertConsent(server.requests.first, attribution: "denied")
        XCTAssertNotNil(server.requests.first?.headers["Clikgate-Installation-Id"])
    }

    func testRegionHintIsSentOnConfig() async throws {
        let core = h.makeCore()
        await core.setConsentRegion("DE")
        await core.start(startTimers: false)
        let q = try XCTUnwrap(server.requests("GET /v1/sdk/config").first?.query)
        XCTAssertTrue(q.contains("region_hint=DE"), q)
        XCTAssertTrue(identifying().isEmpty, "DE is in required_regions: buffering")
    }

    // MARK: - Click ids

    func testClickIdParsing() {
        let ids = GoogleClickIds.parse(URL(string: "https://inv.myapp.com/x?gclid=%20Cj0K-a_b%20&wbraid=W1&gbraid=")!)
        XCTAssertEqual(ids, GoogleClickIds(gclid: "Cj0K-a_b", gbraid: nil, wbraid: "W1"))
        XCTAssertNil(GoogleClickIds.parse(URL(string: "https://inv.myapp.com/x?utm_source=a")!))
        let long = String(repeating: "a", count: 513)
        XCTAssertNil(GoogleClickIds.parse(URL(string: "https://inv.myapp.com/x?gclid=\(long)")!))
        let json = GoogleClickIds(gbraid: "G").json(source: "deep_link")
        XCTAssertEqual(json["source"] as? String, "deep_link")
        XCTAssertTrue(json["gclid"] is NSNull)
    }

    func testClickIdsOnInstallResolveAndOpen() async throws {
        let core = h.makeCore()
        await core.resolve(url: URL(string: "https://inv.myapp.com/p?gbraid=0AAAAAtestgbraid")!)   // launch URL
        await core.start(startTimers: false)
        let install = try XCTUnwrap(server.requests("POST /v1/sdk/install").first).json
        let ids = install["google_click_ids"] as? [String: Any]
        XCTAssertEqual(ids?["gbraid"] as? String, "0AAAAAtestgbraid")
        XCTAssertEqual(ids?["source"] as? String, "deep_link")

        await core.resolve(url: URL(string: "https://inv.myapp.com/p/dress?gclid=Cj0KCQjw-test_gclid")!)
        let resolve = try XCTUnwrap(server.requests("POST /v1/sdk/resolve").last).json
        XCTAssertEqual((resolve["google_click_ids"] as? [String: Any])?["gclid"] as? String, "Cj0KCQjw-test_gclid")
        await core.sendOpen(coldStart: false)
        await core.sendOpen(coldStart: false)
        let opens = server.requests("POST /v1/sdk/open")
        XCTAssertEqual((opens.first?.json["google_click_ids"] as? [String: Any])?["gclid"] as? String, "Cj0KCQjw-test_gclid")
        XCTAssertNil(opens.last?.json["google_click_ids"], "sent once")
    }

    // MARK: - Version policy

    func testVersionComparison() {
        XCTAssertEqual(SemVer.compare("1.2.0", "1.10.0"), -1)
        XCTAssertEqual(SemVer.compare("1.2.0", "1.2"), 0)
        XCTAssertEqual(SemVer.compare("2.0.0-beta", "1.9.9"), 1)
        XCTAssertEqual(SDKCall.name(path: "v1/sdk/push-token"), "push_token")
        XCTAssertEqual(SDKCall.name(path: "v1/sdk/referrals/apply-code"), "referrals")
        XCTAssertEqual(SDKCall.name(path: "v1/sdk/attest/challenge"), "attest")
        XCTAssertEqual(SDKCall.name(path: "v1/sdk/install-ping"), "install_ping")
    }

    func testDeprecatedVersionWorksNormally() async {
        stubConfig("config_response_deprecated")
        let core = h.makeCore()
        await core.start(startTimers: false)
        XCTAssertEqual(server.requests("POST /v1/sdk/install").count, 1)
        let blocked = await core.isBlocked
        XCTAssertFalse(blocked)
    }

    func testBlockedVersionSendsOnlySafeBasicCalls() async throws {
        stubConfig("config_response_blocked")
        h.firebase = FakeFirebase(available: true, instanceId: "abc")
        let core = h.makeCore()
        await core.enableFirebaseForwarding(ClikgateFirebaseForwardingOptions(mirrorEvents: true))
        await core.setPushToken("a1b2c3d4", provider: "apns")
        let box = collect(h.dispatcher)
        await core.start(startTimers: false)
        let install = try XCTUnwrap(server.requests("POST /v1/sdk/install").first).json
        XCTAssertEqual(Set(install.keys), ["installation_id", "app_version", "sdk_version", "platform", "consent"])

        await core.identifyUser(label: nil, customerId: "u1", identityToken: nil)
        await core.track(name: "purchase", revenue: nil, properties: ["order_id": .string("A-1")])
        await core.track(name: "level_up", revenue: nil, properties: nil)
        await core.flush()
        let events = server.requests("POST /v1/sdk/events").flatMap { ($0.json["events"] as? [[String: Any]]) ?? [] }
        XCTAssertEqual(events.map { $0["name"] as? String }, ["purchase"])
        XCTAssertNil(events.first?["properties"])
        XCTAssertTrue(server.requests("POST /v1/sdk/identify").isEmpty)
        XCTAssertTrue(server.requests("POST /v1/sdk/push-token").isEmpty)

        await core.resolve(url: URL(string: "https://inv.myapp.com/p/dress")!)
        await drainMain()
        XCTAssertTrue(server.requests("POST /v1/sdk/resolve").isEmpty)
        XCTAssertEqual(box.items.last?.path, "/p/dress", "delivered locally")
        XCTAssertTrue(h.firebase.events.isEmpty, "no Firebase forwarding when blocked")
    }

    // MARK: - Firebase forwarding

    private func firebaseConfig() {
        stubConfig("config_response_consent_required")
    }

    func testFirebaseForwardingWhenPresent() async throws {
        firebaseConfig()
        server.on("POST /v1/sdk/install", .fixture("install_response_attributed_source"))
        h.firebase = FakeFirebase(available: true, instanceId: "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d")
        let core = h.makeCore()
        await core.setConsent(analytics: .granted, attribution: .granted, adUserData: nil, adPersonalization: nil)
        await core.enableFirebaseForwarding(ClikgateFirebaseForwardingOptions(mirrorEvents: true, eventNameMap: ["purchase": "cg_purchase"]))
        await core.start(startTimers: false)

        let install = try XCTUnwrap(server.requests("POST /v1/sdk/install").first).json
        XCTAssertEqual(install["app_instance_id"] as? String, "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d")
        let attribution = try XCTUnwrap(h.firebase.events.first { $0.0 == "clikgate_attribution" })
        XCTAssertEqual(attribution.1["cg_source"] as? String, "google")
        XCTAssertEqual(attribution.1["cg_medium"] as? String, "cpc")
        XCTAssertEqual(attribution.1["cg_campaign"] as? String, "lagos_launch")
        XCTAssertEqual(attribution.1["cg_channel"] as? String, "ads")
        XCTAssertEqual(attribution.1["cg_match_type"] as? String, "app_link")
        XCTAssertEqual(attribution.1["cg_link_id"] as? String, "lnk_01JAB3C4D5E6F7G8H9JKMNPQRS")
        XCTAssertEqual(h.firebase.userProperties["cg_first_source"] ?? nil, "google")
        XCTAssertEqual(h.firebase.userProperties["cg_first_campaign"] ?? nil, "lagos_launch")

        await core.track(name: "purchase", revenue: ClikgateMoney.ofMinor(150_000, currency: "NGN"),
                         properties: ["order_id": .string("A-1"), "nested": .object([:]), "vip": .bool(true)])
        let mirrored = try XCTUnwrap(h.firebase.events.first { $0.0 == "cg_purchase" })
        XCTAssertEqual(mirrored.1["value"] as? Double, 1500)
        XCTAssertEqual(mirrored.1["currency"] as? String, "NGN")
        XCTAssertEqual(mirrored.1["order_id"] as? String, "A-1")
        XCTAssertEqual(mirrored.1["vip"] as? Int, 1)
        XCTAssertNil(mirrored.1["nested"])

        // Once per installation.
        let next = h.makeCore()
        await next.enableFirebaseForwarding(ClikgateFirebaseForwardingOptions())
        await next.start(startTimers: false)
        XCTAssertEqual(h.firebase.events.filter { $0.0 == "clikgate_attribution" }.count, 1)
        // app_instance_id goes on /open only when it changes.
        XCTAssertNil(server.requests("POST /v1/sdk/open").first?.json["app_instance_id"])
    }

    func testFirebaseAbsentOrNotEnabled() async throws {
        firebaseConfig()
        h.firebase = FakeFirebase(available: false, instanceId: "x")
        var core = h.makeCore()
        await core.setConsent(analytics: .granted, attribution: .granted, adUserData: nil, adPersonalization: nil)
        await core.enableFirebaseForwarding(ClikgateFirebaseForwardingOptions())
        await core.start(startTimers: false)
        XCTAssertTrue(h.firebase.events.isEmpty)
        XCTAssertNil(server.requests("POST /v1/sdk/install").first?.json["app_instance_id"])
        h.cleanUp()

        // Present, but the app didn't enable it.
        server.reset(); stubHappyPath(); firebaseConfig()
        h = Harness()
        h.firebase = FakeFirebase(available: true, instanceId: "x")
        core = h.makeCore()
        await core.setConsent(analytics: .granted, attribution: .granted, adUserData: nil, adPersonalization: nil)
        await core.start(startTimers: false)
        XCTAssertTrue(h.firebase.events.isEmpty)
        h.cleanUp()

        // Present and enabled, but analytics denied.
        server.reset(); stubHappyPath(); firebaseConfig()
        h = Harness()
        h.firebase = FakeFirebase(available: true, instanceId: "x")
        core = h.makeCore()
        await core.setConsent(analytics: .denied, attribution: .granted, adUserData: nil, adPersonalization: nil)
        await core.enableFirebaseForwarding(ClikgateFirebaseForwardingOptions())
        await core.start(startTimers: false)
        XCTAssertTrue(h.firebase.events.isEmpty)
        XCTAssertNil(server.requests("POST /v1/sdk/install").first?.json["app_instance_id"])
    }

    func testFirebaseLimits() {
        XCTAssertTrue(FirebaseLimits.isValidName("purchase_done"))
        XCTAssertFalse(FirebaseLimits.isValidName("1purchase"))
        XCTAssertFalse(FirebaseLimits.isValidName("firebase_x"))
        XCTAssertFalse(FirebaseLimits.isValidName("ga_x"))
        XCTAssertFalse(FirebaseLimits.isValidName("has-dash"))
        XCTAssertFalse(FirebaseLimits.isValidName(String(repeating: "a", count: 41)))
        var props: [String: JSONValue] = ["long": .string(String(repeating: "x", count: 150))]
        for i in 0..<40 { props["p\(i)"] = .int(Int64(i)) }
        let p = FirebaseLimits.parameters(from: props, revenue: ClikgateMoney.ofMinor(1000, currency: "JPY"))
        XCTAssertEqual(p.count, 25)
        XCTAssertEqual(p["value"] as? Double, 1000, "zero-decimal currency")
        XCTAssertTrue(p.values.compactMap { $0 as? String }.allSatisfy { $0.count <= 100 })
        let one = FirebaseLimits.parameters(from: ["long": .string(String(repeating: "x", count: 150))], revenue: nil)
        XCTAssertEqual((one["long"] as? String)?.count, 100)
    }

    // MARK: - attributionMetadata

    func testAttributionMetadata() async throws {
        server.on("POST /v1/sdk/install", .fixture("install_response_referral"))
        let core = h.makeCore()
        await core.start(startTimers: false)
        XCTAssertEqual(core.snapshot.metadata, ["cg_click_id": "clk_01JAB3C4D5E6F7G8H9JKMNPQRS", "cg_link_id": "lnk_01JAB3C4D5E6F7G8H9JKMNPQRS"])
        await core.resolve(url: URL(string: "https://inv.myapp.com/p/dress")!)
        XCTAssertEqual(core.snapshot.metadata["cg_link_id"], "lnk_01JAB3C4D5E6F7G8H9JKMNPQRS")
        XCTAssertEqual(core.snapshot.metadata["cg_click_id"], "clk_01JAB3C4D5E6F7G8H9JKMNPQRS")
        await core.setTrackingEnabled(false)
        XCTAssertTrue(core.snapshot.metadata.isEmpty)
    }

    func testAttributionMetadataEmptyForOrganic() async {
        let core = h.makeCore()
        await core.start(startTimers: false)
        XCTAssertTrue(core.snapshot.metadata.isEmpty)
    }

    // MARK: - Clipboard (opt-in)

    func testClipboardIsOffByDefault() async {
        XCTAssertEqual(ClikgateOptions().pasteboardMode, .off)
        h.pasteboard.detect = true
        h.pasteboard.text = "https://inv.myapp.com/_cg/p/\(token)"
        let core = h.makeCore(options: ClikgateOptions(linkDomains: ["inv.myapp.com"], logLevel: .none))
        await core.start(startTimers: false)
        XCTAssertEqual(h.pasteboard.detections, 0)
        XCTAssertEqual(h.pasteboard.reads, 0)
    }

    func testClipboardTokenKeptUntilGrant() async throws {
        stubConfig("config_response_consent_required")
        h.pasteboard.detect = true
        h.pasteboard.text = "https://inv.myapp.com/_cg/p/\(token)"
        let core = h.makeCore()
        await core.start(startTimers: false)
        XCTAssertEqual(h.pasteboard.reads, 1)
        XCTAssertTrue(server.requests("POST /v1/sdk/install").isEmpty)
        await core.setConsent(analytics: nil, attribution: .granted, adUserData: nil, adPersonalization: nil)
        XCTAssertEqual(server.requests("POST /v1/sdk/install").first?.json["pasteboard_token"] as? String, token)
        XCTAssertEqual(h.pasteboard.reads, 1)
    }

    // MARK: - Identity checks

    func testDeviceCheckAndIdfvWithFeatureAndConsent() async throws {
        stubConfig { c in self.features(&c) { $0["identity_checks"] = true } }
        h.deviceCheck = FakeDeviceCheck(supported: true)
        let core = h.makeCore()
        await core.start(startTimers: false)
        let body = try XCTUnwrap(server.requests("POST /v1/sdk/install").first).json
        XCTAssertEqual(body["device_check_token"] as? String, "ZGV2aWNlY2hlY2stdG9rZW4=")
        XCTAssertEqual(body["idfv"] as? String, "6F9619FF-8B86-D011-B42D-00C04FC964FF")
    }

    func testIdentityChecksNeedAnalyticsUnlessFraudPreventionBasis() async throws {
        for (basis, expectSent) in [("consent", false), ("fraud_prevention", true)] {
            server.reset(); stubHappyPath()
            stubConfig("config_response_consent_required") { c in
                self.features(&c) { $0["identity_checks"] = true }
                var x = c["consent"] as! [String: Any]
                x["identity_checks_basis"] = basis
                c["consent"] = x
            }
            h = Harness()
            h.deviceCheck = FakeDeviceCheck(supported: true)
            let core = h.makeCore()
            await core.setConsent(analytics: .denied, attribution: .granted, adUserData: nil, adPersonalization: nil)
            await core.start(startTimers: false)
            let body = try XCTUnwrap(server.requests("POST /v1/sdk/install").first).json
            XCTAssertEqual(body["device_check_token"] != nil, expectSent, basis)
            XCTAssertEqual(body["idfv"] != nil, expectSent, basis)
            h.cleanUp()
        }
    }

    func testUnsupportedDeviceCheckIsOmitted() async throws {
        stubConfig { c in self.features(&c) { $0["identity_checks"] = true } }
        h.deviceCheck = FakeDeviceCheck(supported: false)
        await h.makeCore().start(startTimers: false)
        let body = try XCTUnwrap(server.requests("POST /v1/sdk/install").first).json
        XCTAssertNil(body["device_check_token"])
        XCTAssertNotNil(body["idfv"])
    }

    // MARK: - Google on-device measurement

    func testOnDeviceMeasurementPassThrough() async throws {
        h.odm = FakeODM(available: true)
        let core = h.makeCore()
        await core.enableGoogleOnDeviceMeasurement()
        await core.start(startTimers: false)
        let odm = try XCTUnwrap(server.requests("POST /v1/sdk/install").first?.json["google_on_device_measurement"] as? [String: Any])
        XCTAssertEqual(odm["odm_info"] as? String, "abcdEfadGdaf")
        XCTAssertEqual(odm["sdk_version"] as? String, "3.7.0")
        let st = await core.currentState()
        XCTAssertEqual(h.odm.firstLaunchDates, [try XCTUnwrap(st.firstLaunchAt)])
        XCTAssertTrue(st.odmCollected)
    }

    func testOnDeviceMeasurementAbsentDisabledEmptyOrDenied() async throws {
        let cases: [(available: Bool, enabled: Bool, info: String?, adUserData: ClikgateConsentState)] = [
            (false, true, "x", .granted), (true, false, "x", .granted), (true, true, nil, .granted), (true, true, "x", .denied),
        ]
        for c in cases {
            server.reset(); stubHappyPath()
            h = Harness()
            h.odm = FakeODM(available: c.available, info: c.info)
            let core = h.makeCore()
            await core.setConsent(analytics: nil, attribution: nil, adUserData: c.adUserData, adPersonalization: nil)
            if c.enabled { await core.enableGoogleOnDeviceMeasurement() }
            await core.start(startTimers: false)
            XCTAssertNil(server.requests("POST /v1/sdk/install").first?.json["google_on_device_measurement"], "\(c)")
            if c.adUserData == .denied || !c.enabled || !c.available { XCTAssertTrue(h.odm.firstLaunchDates.isEmpty, "\(c)") }
            h.cleanUp()
        }
    }

    // MARK: - Response fields, facade

    func testInstallResponseSourceFields() {
        let r = InstallResponse(json: Fixtures.json("install_response_attributed_source"))
        XCTAssertEqual(r?.attribution?.source, "google")
        XCTAssertEqual(r?.attribution?.medium, "cpc")
        XCTAssertEqual(r?.attribution?.campaign, "lagos_launch")
        XCTAssertEqual(r?.attribution?.channel, "ads")
        let organic = InstallResponse(json: Fixtures.json("install_response_organic"))
        XCTAssertNil(organic?.attribution?.channel)
    }

    func testConfigParsing() {
        let c = RemoteConfig(json: Fixtures.json("config_response_blocked"))
        XCTAssertEqual(c.versionStatus, "blocked")
        XCTAssertEqual(c.blocked?.allowedEvents, ["purchase", "sign_up"])
        XCTAssertEqual(c.latestVersion, "1.4.0")
        let r = RemoteConfig(json: Fixtures.json("config_response_consent_required"))
        XCTAssertEqual(r.consent?.mode, "required_in_regions")
        XCTAssertEqual(r.consent?.anonymousCounts, true)
        XCTAssertEqual(r.firebase?.mirrorEvents, true)
        var old = Fixtures.json("config_response_legacy")
        for k in ["consent", "blocked_instructions", "firebase_forwarding", "version_status", "min_supported_version", "latest_version"] {
            old.removeValue(forKey: k)
        }
        let legacy = RemoteConfig(json: old)
        XCTAssertNil(legacy.consent)
        XCTAssertNil(legacy.blocked)
        XCTAssertNil(legacy.firebase)
    }

    func testFacadeBeforeConfigure() async {
        let sdk = Clikgate()
        sdk.setConsent(analytics: .granted, attribution: nil, adUserData: nil, adPersonalization: nil)
        sdk.setConsent(attribution: .denied)
        XCTAssertTrue(sdk.setConsentRegionValidated("de"))
        XCTAssertFalse(sdk.setConsentRegionValidated("Germany"))
        let c = sdk.getConsent()
        XCTAssertEqual(c.analytics, .granted)
        XCTAssertEqual(c.attribution, .denied)
        XCTAssertEqual(c.adUserData, .unknown)
        XCTAssertEqual(c.region, "DE")
        XCTAssertTrue(sdk.attributionMetadata().isEmpty)

        sdk.configure(sdkKey: "cg_sdk_test", options: ClikgateOptions(linkDomains: ["inv.myapp.com"], logLevel: .none),
                      deps: h.deps(), startTimers: false)
        await eventually { sdk.getConsent().isRequired == true }
        let q = server.requests("GET /v1/sdk/config").first?.query ?? ""
        XCTAssertTrue(q.contains("region_hint=DE"))
        XCTAssertEqual(sdk.getConsent().analytics, .granted)
    }
}
