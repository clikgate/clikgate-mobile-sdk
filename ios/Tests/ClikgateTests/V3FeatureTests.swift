import XCTest
import UIKit
@testable @_spi(ClikgateWrapper) @_spi(ClikgateEngage) import Clikgate

/// Spec v3 core surface: feature switches, referee-side referral gating and the internal request
/// context the Engage add-on uses (leaderboards, codes and share are tested in ClikgateEngageTests).
/// Runs through the public API on isolated `Clikgate` instances with the stub server.
final class V3FeatureTests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared

    static let board = "lb_01JAB3C4D5E6F7G8H9JKMNPQRS"
    static let program = "rpg_01JAB3C4D5E6F7G8H9JKMNPQRS"

    override func setUp() { super.setUp(); server.reset(); h = Harness() }
    override func tearDown() { h.cleanUp(); super.tearDown() }

    // MARK: Helpers

    /// `config_response` with some `features` entries replaced (nil removes the key).
    static func config(_ overrides: [String: Any?] = [:]) -> StubResponse {
        var j = Fixtures.json("config_response")
        var f = j["features"] as? [String: Any] ?? [:]
        for (k, v) in overrides { f[k] = v }
        j["features"] = f
        return StubResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: j))
    }

    /// A configured instance whose first `/install` has completed.
    private func installed(config: StubResponse = config(), identify: Bool = true) async throws -> Clikgate {
        stubHappyPath()
        server.on("GET /v1/sdk/config", config)
        let sdk = Clikgate()
        sdk.configure(sdkKey: "cg_sdk_test", options: ClikgateOptions(linkDomains: ["inv.myapp.com"], logLevel: .none),
                      deps: h.deps(), startTimers: false)
        for _ in 0..<300 {
            if let c = sdk.currentCore, await c.currentState().installDone { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let done = await sdk.currentCore?.currentState().installDone
        XCTAssertEqual(done, true, "install did not complete")
        if identify, let c = sdk.currentCore {
            await c.identifyUser(label: nil, customerId: "user_42", identityToken: "sig.1760954400")
        }
        return sdk
    }

    private func expectError<T>(_ code: String, file: StaticString = #filePath, line: UInt = #line,
                                _ work: () async throws -> T) async -> ClikgateError? {
        do {
            _ = try await work()
            XCTFail("expected \(code)", file: file, line: line)
            return nil
        } catch let e as ClikgateError {
            XCTAssertEqual(e.code, code, file: file, line: line)
            return e
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
            return nil
        }
    }

    private func count(_ prefix: String) -> Int {
        server.requests.filter { $0.key.hasPrefix(prefix) }.count
    }

    // MARK: Feature switches

    func testSwitchesParsedFromConfigFixture() {
        let c = RemoteConfig(json: Fixtures.json("config_response"))
        let f = FeatureSwitches(switches: c.switches)
        XCTAssertTrue(f.isEnabled(ClikgateFeatures.referrals))
        XCTAssertTrue(f.isEnabled(ClikgateFeatures.leaderboards))
        XCTAssertTrue(f.isEnabled(ClikgateFeatures.offlineCodes))
        XCTAssertTrue(f.isEnabled(ClikgateFeatures.uninstallTracking))
        XCTAssertFalse(f.isEnabled(ClikgateFeatures.identityChecks))
        XCTAssertFalse(f.isEnabled(ClikgateFeatures.skanPostbacks))
        XCTAssertFalse(f.isEnabled("pasteboard_matching"), "non-boolean entries aren't switches")
        XCTAssertFalse(f.isEnabled("attestation"))
        XCTAssertFalse(f.isEnabled("no_such_feature"), "unknown keys are off")
    }

    func testDefaultsBeforeConfigAndForMissingKeys() {
        let none = FeatureSwitches()
        for on in ["referrals", "leaderboards", "offline_codes", "app_attribution"] { XCTAssertTrue(none.isEnabled(on), on) }
        for off in ["identity_checks", "whatsapp_attribution", "skan_postbacks", "uninstall_tracking", "unknown"] {
            XCTAssertFalse(none.isEnabled(off), off)
        }
        // An older server's features object without the v3 keys.
        let old = RemoteConfig(json: ["features": ["uninstall_tracking": true, "pasteboard_matching": "off"]])
        let f = FeatureSwitches(switches: old.switches)
        XCTAssertTrue(f.isEnabled("leaderboards"))
        XCTAssertTrue(f.isEnabled("uninstall_tracking"))
        XCTAssertFalse(f.isEnabled("identity_checks"))
        // Not configured: catalogue defaults.
        let sdk = Clikgate()
        XCTAssertTrue(sdk.isFeatureEnabled("leaderboards"))
        XCTAssertFalse(sdk.isFeatureEnabled("identity_checks"))
        XCTAssertFalse(sdk.isFeatureEnabled("bogus"))
    }

    func testCachedSwitchesAreLoadedSynchronouslyOnRelaunch() async throws {
        stubHappyPath()
        server.on("GET /v1/sdk/config", Self.config(["leaderboards": false]))
        let first = h.makeCore()
        await first.start(startTimers: false)
        XCTAssertFalse(first.features.isEnabled("leaderboards"))

        // Same storage directory: the new core knows the switch before start() / any fetch.
        let second = h.makeCore()
        XCTAssertFalse(second.features.isEnabled("leaderboards"))
        XCTAssertTrue(second.features.isEnabled("referrals"))
    }

    func testFacadeReflectsFetchedConfig() async throws {
        let sdk = try await installed(config: Self.config(["leaderboards": false, "identity_checks": true]))
        XCTAssertFalse(sdk.isFeatureEnabled(ClikgateFeatures.leaderboards))
        XCTAssertTrue(sdk.isFeatureEnabled(ClikgateFeatures.identityChecks))
        XCTAssertTrue(sdk.isFeatureEnabled(ClikgateFeatures.offlineCodes))
    }

    // MARK: Feature off: no network

    func testSwitchedOffReferralsFailFastWithoutNetwork() async throws {
        let sdk = try await installed(config: Self.config(["referrals": false]))
        let before = server.requests.count
        let e1 = await expectError(ClikgateError.featureDisabled) { try await sdk.referrals.referredBy() }
        XCTAssertEqual(e1?.feature, "referrals")
        _ = await expectError(ClikgateError.featureDisabled) { try await sdk.referrals.applyCode(programId: Self.program, code: "ADA42") }
        XCTAssertEqual(server.requests.count, before, "no request for a switched-off feature")
    }

    // MARK: Server no-op body

    func testServerFeatureDisabledBodyMarksFeatureOffAndRefreshesConfig() async throws {
        let sdk = try await installed()
        // Background refresh fails: the in-memory switch-off stays.
        server.on("GET /v1/sdk/config", .json(#"{"error":{"type":"server_error","code":"server_error","message":"x"}}"#, status: 500))
        server.on("POST /v1/sdk/referrals/apply-code", .fixture("feature_disabled"))
        let configBefore = server.requests("GET /v1/sdk/config").count

        let e = await expectError(ClikgateError.featureDisabled) { try await sdk.referrals.applyCode(programId: Self.program, code: "ADA42") }
        XCTAssertEqual(e?.feature, "leaderboards", "the body names the feature")
        XCTAssertFalse(sdk.isFeatureEnabled("leaderboards"))
        XCTAssertFalse(sdk.isFeatureEnabled("referrals"), "the method's feature is marked off too")
        await eventually { self.server.requests("GET /v1/sdk/config").count == configBefore + 1 }

        _ = await expectError(ClikgateError.featureDisabled) { try await sdk.referrals.applyCode(programId: Self.program, code: "ADA42") }
        XCTAssertEqual(server.requests("POST /v1/sdk/referrals/apply-code").count, 1, "second call: no network")
        XCTAssertEqual(server.requests("GET /v1/sdk/config").count, configBefore + 1, "a single attempt for the refresh")
    }

    func testFreshConfigReEnablesAFeatureTheServerSwitchedOff() async throws {
        let sdk = try await installed()
        server.on("GET /v1/sdk/referrals/referred-by", .json(#"{"accepted": false, "reason": "feature_disabled"}"#))
        let e = await expectError(ClikgateError.featureDisabled) { try await sdk.referrals.referredBy() }
        XCTAssertEqual(e?.feature, "referrals", "method feature when the body doesn't name one")
        // The refresh returns the fixture config (referrals: true) and clears the switch-off.
        await eventually { sdk.isFeatureEnabled("referrals") }
        server.on("GET /v1/sdk/referrals/referred-by", .fixture("referred_by_response"))
        let by = try await sdk.referrals.referredBy()
        XCTAssertTrue(by.referred)
    }

    func testAcceptedBodyIsNotTreatedAsDisabled() {
        XCTAssertTrue(FeatureSwitches.isFeatureDisabledBody(Fixtures.json("feature_disabled")))
        XCTAssertFalse(FeatureSwitches.isFeatureDisabledBody(["accepted": true, "reason": "feature_disabled"]))
        XCTAssertFalse(FeatureSwitches.isFeatureDisabledBody(["reason": "feature_disabled"]))
        XCTAssertFalse(FeatureSwitches.isFeatureDisabledBody(Fixtures.json("referred_by_response")))
        XCTAssertFalse(FeatureSwitches.isFeatureDisabledBody(nil))
    }

    func testFeatureDisabledErrorUserInfo() {
        let e = ClikgateError.featureDisabledError("leaderboards")
        XCTAssertEqual(e.code, "feature_disabled")
        XCTAssertEqual(e.feature, "leaderboards")
        XCTAssertEqual((e as NSError).userInfo["feature"] as? String, "leaderboards")
    }

    // MARK: Internal request context (Engage add-on)

    func testRequestContextAfterInstallAndIdentify() async throws {
        let sdk = try await installed()
        let ctx = try await sdk.requestContext()
        let state = await sdk.currentCore!.currentState()
        XCTAssertEqual(ctx.installationId, state.installationId)
        XCTAssertEqual(ctx.sdkKey, "cg_sdk_test")
        XCTAssertEqual(ctx.environment, "production")
        XCTAssertEqual(ctx.apiBaseUrl, ClikgateOptions().apiBaseUrl)
        XCTAssertEqual(ctx.customerUserId, "user_42")
        XCTAssertEqual(ctx.identityToken, "sig.1760954400")
        XCTAssertEqual(ctx.sdkVersion, "ios/\(Clikgate.sdkVersion)")
        XCTAssertNil(ctx.nativeSdkVersion)
        XCTAssertEqual(ctx.headers["Clikgate-Identity-Token"], "sig.1760954400")
        XCTAssertEqual(ctx.headers["Clikgate-Installation-Id"], state.installationId)
        XCTAssertNil(ctx.headers["Clikgate-SDK-Native-Version"])
    }

    func testRequestContextSendsPendingIdentifyFirst() async throws {
        let sdk = try await installed(identify: false)
        // Identify while /identify fails (5 attempts): it stays pending; the context call sends it again.
        server.on("POST /v1/sdk/identify", .offline(), .offline(), .offline(), .offline(), .offline(), .fixture("identify_response"))
        await sdk.currentCore!.identifyUser(label: nil, customerId: "user_7", identityToken: nil)
        let pending = await sdk.currentCore!.currentState().identifyPending
        XCTAssertTrue(pending)
        let before = server.requests("POST /v1/sdk/identify").count
        let ctx = try await sdk.requestContext()
        XCTAssertEqual(ctx.customerUserId, "user_7")
        XCTAssertNil(ctx.identityToken)
        XCTAssertGreaterThan(server.requests("POST /v1/sdk/identify").count, before)
    }

    func testRequestContextWrapped() async throws {
        stubHappyPath()
        let core = h.makeCore(wrapper: WrapperInfo(name: "flutter", version: "1.2.3"))
        await core.start(startTimers: false)
        let ctx = try await core.requestContext()
        XCTAssertEqual(ctx.sdkVersion, "flutter/1.2.3")
        XCTAssertEqual(ctx.nativeSdkVersion, "ios/\(Clikgate.sdkVersion)")
        XCTAssertNil(ctx.customerUserId)
    }

    func testRequestContextGates() async throws {
        _ = await expectError(ClikgateError.notConfigured) { try await Clikgate().requestContext() }
        stubHappyPath()
        let never = h.makeCore()   // never started: no install
        _ = await expectError(ClikgateError.installPending) { try await never.requestContext() }

        let sdk = try await installed()
        sdk.setTrackingEnabled(false)
        await eventually { self.server.requests("POST /v1/sdk/opt-out").count == 1 }
        _ = await expectError(ClikgateError.optedOut) { try await sdk.requestContext() }
    }

    func testReportServerError() async throws {
        let sdk = try await installed()
        let configBefore = server.requests("GET /v1/sdk/config").count
        sdk.reportServerError(code: ClikgateError.featureDisabled, feature: "leaderboards")
        XCTAssertFalse(sdk.isFeatureEnabled("leaderboards"), "marked off synchronously")
        await eventually { self.server.requests("GET /v1/sdk/config").count == configBefore + 1 }
        await eventually { sdk.isFeatureEnabled("leaderboards") }   // the fresh config re-enables it

        sdk.reportServerError(code: "code_not_found", feature: nil)  // ignored
        _ = try await sdk.requestContext()

        sdk.reportServerError(code: ClikgateError.invalidSdkKey, feature: nil)
        var code: String?
        for _ in 0..<200 {
            do { _ = try await sdk.requestContext() } catch let e as ClikgateError { code = e.code }
            if code == ClikgateError.invalidSdkKey { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(code, ClikgateError.invalidSdkKey)
    }

    func testReportInstallationUnknownReRunsInstall() async throws {
        let sdk = try await installed()
        let installs = server.requests("POST /v1/sdk/install").count
        sdk.reportServerError(code: ClikgateError.installationUnknown, feature: nil)
        await eventually { self.server.requests("POST /v1/sdk/install").count == installs + 1 }
    }
}
