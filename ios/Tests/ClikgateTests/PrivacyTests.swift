import XCTest
@testable import Clikgate

/// Change 03 (S.2): the iOS SDK sends no signal used only for probabilistic matching or
/// fingerprinting (`screen`, jailbreak heuristics `is_rooted`). `is_emulator` is a compile-time flag.
final class PrivacyTests: XCTestCase {
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

    func testInstallSendsNoScreenAndNoJailbreakSignal() async throws {
        stubHappyPath()
        await h.makeCore().start(startTimers: false)
        let body = try XCTUnwrap(server.requests("POST /v1/sdk/install").first).json
        XCTAssertNil(body["screen"])
        XCTAssertNil(body["is_rooted"])
        XCTAssertEqual(body["is_emulator"] as? Bool, false)
        // Analytics fields stay.
        XCTAssertEqual(body["device_model"] as? String, "iPhone15,2")
        XCTAssertEqual(body["locale"] as? String, "en-NG")
        XCTAssertEqual(body["timezone"] as? String, "Africa/Lagos")
        // Every key is in the 1.2.0 iOS fixture (or optional in the schema).
        let fixture = Fixtures.json("install_request_ios")
        let optional: Set<String> = ["attestation", "apple_search_ads_token", "app_instance_id", "idfv", "keychain_previous_installation_id"]
        XCTAssertTrue(Set(body.keys).isSubset(of: Set(fixture.keys).union(optional)), "\(Set(body.keys).subtracting(fixture.keys))")
    }

    func testSimulatorFlagIsStillSent() async throws {
        h.device = FakeDevice(isSimulator: true)
        stubHappyPath()
        await h.makeCore().start(startTimers: false)
        let body = try XCTUnwrap(server.requests("POST /v1/sdk/install").first).json
        XCTAssertEqual(body["is_emulator"] as? Bool, true)
    }

    func testRequestModelHasNoFingerprintFields() {
        let req = InstallRequest(installationId: "b8c2d4e6-1a3c-4e5f-8a7b-9c0d1e2f3a4b", keychainPreviousInstallationId: nil,
                                 appVersion: "3.4.1", sdkVersion: "1.2.0", osVersion: nil, deviceModel: nil, locale: nil,
                                 timezone: nil, launchUrl: nil, pasteboardToken: nil, push: nil, attestation: nil,
                                 appleSearchAdsToken: nil, trackingAllowed: true, isEmulator: nil)
        let json = req.json
        XCTAssertNil(json["screen"]); XCTAssertNil(json["is_rooted"]); XCTAssertNil(json["is_emulator"])
    }

    func testIdentityCheckSignalsOnlyWithTheFeatureAndConsent() async throws {
        h.deviceCheck = FakeDeviceCheck(supported: true)
        stubHappyPath()   // config_response: identity_checks false, App Attest off
        await h.makeCore().start(startTimers: false)
        let body = try XCTUnwrap(server.requests("POST /v1/sdk/install").first).json
        XCTAssertNil(body["device_check_token"], "no identity checks without the feature")
        XCTAssertNil(body["idfv"])
        XCTAssertEqual(h.deviceCheck.calls, 0)
    }
}
