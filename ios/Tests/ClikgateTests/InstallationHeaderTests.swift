import XCTest
import Security
@testable import Clikgate

/// `installationHeader()`: `Clikgate-Installation: <app ID>:<installation ID>` for the app's own server.
final class InstallationHeaderTests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared
    let appId = "app_01JAB3C4D5E6F7G8H9JKMNPQRS"   // config_response.json

    override func setUp() {
        super.setUp()
        server.reset()
        h = Harness()
        stubHappyPath()
    }

    override func tearDown() {
        h.cleanUp()
        super.tearDown()
    }

    private func configWithoutAppId() {
        var c = Fixtures.json("config_response")
        c.removeValue(forKey: "app_id")
        server.on("GET /v1/sdk/config", StubResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: c)))
    }

    func testValueIsTheConfigAppIdAndTheInstallationId() async {
        let core = h.makeCore()
        await core.start(startTimers: false)
        let header = await core.installationHeaderForApp()
        let id = await core.installationIdForApp()
        XCTAssertEqual(header?.name, "Clikgate-Installation")
        XCTAssertEqual(header?.value, "\(appId):\(id!)")
        XCTAssertEqual(id, id?.lowercased())
    }

    func testNilAfterOptOutAndBackAfterOptIn() async {
        let core = h.makeCore()
        await core.start(startTimers: false)
        let before = await core.installationHeaderForApp()
        await core.setTrackingEnabled(false)
        let off = await core.installationHeaderForApp()
        XCTAssertNil(off)
        await core.setTrackingEnabled(true)
        let on = await core.installationHeaderForApp()
        XCTAssertEqual(on?.value, before?.value)
    }

    func testNilInDeepLinkOnlyMode() async {
        server.on("GET /v1/sdk/config", .fixture("config_response_deep_link_only"))
        let core = h.makeCore()
        await core.start(startTimers: false)
        let header = await core.installationHeaderForApp()
        XCTAssertNil(header)
    }

    func testNilWhileConsentIsRequiredAndNotGivenThenDeniedAndSetOnGrant() async {
        server.on("GET /v1/sdk/config", .fixture("config_response_consent_required"))
        let core = h.makeCore()
        await core.start(startTimers: false)
        var header = await core.installationHeaderForApp()
        XCTAssertNil(header, "consent not given yet where it's required")
        await core.setConsent(analytics: nil, attribution: .denied, adUserData: nil, adPersonalization: nil)
        header = await core.installationHeaderForApp()
        XCTAssertNil(header, "consent denied")
        await core.setConsent(analytics: nil, attribution: .granted, adUserData: nil, adPersonalization: nil)
        header = await core.installationHeaderForApp()
        let id = await core.installationIdForApp()
        XCTAssertEqual(header?.value, "\(appId):\(id!)")
    }

    func testNilWhenNoConfigHasGivenTheAppId() async {
        configWithoutAppId()
        let core = h.makeCore()
        await core.start(startTimers: false)
        let header = await core.installationHeaderForApp()
        XCTAssertNil(header)
    }

    func testNilOnAnOfflineFirstLaunch() async {
        server.on("GET /v1/sdk/config", .offline())
        server.on("POST /v1/sdk/install", .offline())
        let core = h.makeCore()
        await core.refreshConfig()
        let header = await core.installationHeaderForApp()
        XCTAssertNil(header)
    }

    func testOfflineRelaunchUsesTheCachedAppId() async {
        let first = h.makeCore()
        await first.start(startTimers: false)
        let online = await first.installationHeaderForApp()
        XCTAssertNotNil(online)
        h.clock.advance(2 * 3600)   // the cached config is stale, the refresh fails
        server.on("GET /v1/sdk/config", .offline())
        let next = h.makeCore()
        await next.refreshConfig()
        let offline = await next.installationHeaderForApp()
        XCTAssertEqual(offline?.value, online?.value)
    }

    func testPublicApiIsNilBeforeConfigureAndNeverThrows() async {
        let header = await Clikgate.shared.installationHeader()
        XCTAssertNil(header)
    }
}

/// The Keychain items are per app: two apps of one team that share a keychain access group never read each
/// other's installation ID, and the item of the service without a bundle ID is ignored.
final class PerAppKeychainTests: XCTestCase {
    let server = StubServer.shared
    let legacyService = "com.clikgate.installation-id"
    let legacyId = "11111111-2222-4333-8444-555555555555"

    override func setUp() {
        super.setUp()
        server.reset()
        stubHappyPath()
    }

    func testTheServiceNamesTheBundleId() {
        let one = SystemKeychain(bundleId: "com.example.one"), two = SystemKeychain(bundleId: "com.example.two")
        XCTAssertEqual(one.service, "com.clikgate.installation-id.com.example.one")
        XCTAssertNotEqual(one.service, two.service)
        XCTAssertNotEqual(one.service, legacyService)
        XCTAssertEqual(one.baseQuery()[kSecAttrService as String] as? String, one.service)
        XCTAssertEqual(one.baseQuery()[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testTwoAppsSharingAnAccessGroupGetDifferentItems() {
        let group = SharedAccessGroup()
        group.put(legacyService, SystemKeychain.account, legacyId)
        let one = group.keychain("com.example.one"), two = group.keychain("com.example.two")
        XCTAssertNil(one.readInstallationId(), "the item without a bundle ID is ignored")
        one.writeInstallationId("aaaaaaaa-0000-4000-8000-000000000001")
        one.writeDeviceMarker("aaaaaaaa-0000-4000-8000-000000000001")
        XCTAssertEqual(one.readInstallationId(), "aaaaaaaa-0000-4000-8000-000000000001")
        XCTAssertNil(two.readInstallationId(), "another app never reads this app's ID")
        XCTAssertNil(two.readDeviceMarker())
        two.writeInstallationId("bbbbbbbb-0000-4000-8000-000000000002")
        XCTAssertEqual(one.readInstallationId(), "aaaaaaaa-0000-4000-8000-000000000001")
        XCTAssertEqual(two.readInstallationId(), "bbbbbbbb-0000-4000-8000-000000000002")
        XCTAssertEqual(group.value(legacyService, SystemKeychain.account), legacyId, "an older SDK's item is left alone")
        XCTAssertEqual(group.accessible(one.service, "device_marker"), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(group.accessible(one.service, SystemKeychain.account), kSecAttrAccessibleAfterFirstUnlock as String)
    }

    func testAPhoneWithTheOldSharedItemStartsAndCreatesItsOwnItems() async {
        let group = SharedAccessGroup()
        group.put(legacyService, SystemKeychain.account, legacyId)
        group.put(legacyService, "device_marker", legacyId)
        let a = Harness(), b = Harness()
        defer { a.cleanUp(); b.cleanUp() }
        let ids = ["aaaaaaaa-0000-4000-8000-000000000001", "bbbbbbbb-0000-4000-8000-000000000002"]
        var cores: [ClikgateCore] = []
        for (n, (h, bundle)) in [(a, "com.example.one"), (b, "com.example.two")].enumerated() {
            h.keychainStore = group.keychain(bundle)
            var d = h.deps()
            let id = ids[n]
            d.uuid = { id }
            cores.append(ClikgateCore(sdkKey: "cg_sdk_test", options: ClikgateOptions(logLevel: .none), deps: d, logger: h.logger,
                                      dispatcher: h.dispatcher, linkDomains: LinkDomainsBox(optionDomains: []), wrapper: nil))
        }
        for c in cores { await c.start(startTimers: false) }
        for (n, c) in cores.enumerated() {
            let id = await c.installationIdForApp()
            XCTAssertEqual(id, ids[n])
            let st = await c.currentState()
            XCTAssertNil(st.keychainPreviousInstallationId, "no app takes the old item or another app's ID for an earlier install")
        }
        XCTAssertEqual(group.value("com.clikgate.installation-id.com.example.one", SystemKeychain.account), ids[0])
        XCTAssertEqual(group.value("com.clikgate.installation-id.com.example.two", SystemKeychain.account), ids[1])
        XCTAssertEqual(group.value("com.clikgate.installation-id.com.example.two", "device_marker"), ids[1])
        XCTAssertEqual(group.value(legacyService, SystemKeychain.account), legacyId, "an older SDK in another app keeps its item")
        let sent = server.requests("POST /v1/sdk/install").compactMap { $0.json["installation_id"] as? String }
        XCTAssertEqual(Set(sent), Set(ids))
    }
}

/// One keychain access group shared by several apps: items keyed by service + account, searched without a group.
final class SharedAccessGroup: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: (data: Data, accessible: String?)] = [:]

    private static func key(_ q: NSDictionary) -> String {
        "\(q[kSecAttrService as String] ?? "")|\(q[kSecAttrAccount as String] ?? "")"
    }

    func put(_ service: String, _ account: String, _ value: String) {
        lock.lock(); items["\(service)|\(account)"] = (Data(value.utf8), nil); lock.unlock()
    }

    func value(_ service: String, _ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return items["\(service)|\(account)"].map { String(decoding: $0.data, as: UTF8.self) }
    }

    func accessible(_ service: String, _ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return items["\(service)|\(account)"]?.accessible
    }

    func keychain(_ bundleId: String) -> SystemKeychain { GroupKeychain(bundleId: bundleId, group: self) }

    func copy(_ q: NSDictionary) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[Self.key(q)]?.data
    }

    func update(_ q: NSDictionary, _ a: NSDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let k = Self.key(q)
        guard items[k] != nil else { return errSecItemNotFound }
        items[k] = (a[kSecValueData as String] as! Data, a[kSecAttrAccessible as String] as? String)
        return errSecSuccess
    }

    func add(_ d: NSDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let k = Self.key(d)
        guard items[k] == nil else { return errSecDuplicateItem }
        items[k] = (d[kSecValueData as String] as! Data, d[kSecAttrAccessible as String] as? String)
        return errSecSuccess
    }
}

/// The real ``SystemKeychain`` queries, answered by a ``SharedAccessGroup`` instead of the Keychain.
final class GroupKeychain: SystemKeychain, @unchecked Sendable {
    let group: SharedAccessGroup
    init(bundleId: String, group: SharedAccessGroup) { self.group = group; super.init(bundleId: bundleId) }
    override func copy(_ q: CFDictionary, _ out: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        guard let d = group.copy(q as NSDictionary) else { return errSecItemNotFound }
        out?.pointee = d as CFData
        return errSecSuccess
    }
    override func update(_ q: CFDictionary, _ attrs: CFDictionary) -> OSStatus { group.update(q as NSDictionary, attrs as NSDictionary) }
    override func add(_ q: CFDictionary) -> OSStatus { group.add(q as NSDictionary) }
}
