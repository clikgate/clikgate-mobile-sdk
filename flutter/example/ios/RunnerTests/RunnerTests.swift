import Flutter
import UIKit
import XCTest
import Clikgate

@testable import clikgate_flutter

/// Unit tests of the plugin's Swift side (method routing and error details). The Clikgate SDK is not
/// configured in the test host (lib/main.dart skips `Clikgate.configure` when AppDelegate reports an XCTest
/// host), so calls that need it answer `not_configured`.
class RunnerTests: XCTestCase {

  private func call(_ method: String, _ args: [String: Any] = [:]) -> Any? {
    let plugin = ClikgateFlutterPlugin()
    let done = expectation(description: method)
    var value: Any?
    plugin.handle(FlutterMethodCall(methodName: method, arguments: args)) { r in
      value = r
      done.fulfill()
    }
    waitForExpectations(timeout: 2)
    return value
  }

  func testIsFeatureEnabledAnswersBeforeConfigureWithDefaults() {
    XCTAssertEqual(call("isFeatureEnabled", ["key": "leaderboards"]) as? Bool, true)
    XCTAssertEqual(call("isFeatureEnabled", ["key": "offline_codes"]) as? Bool, true)
    XCTAssertEqual(call("isFeatureEnabled", ["key": "identity_checks"]) as? Bool, false)
    XCTAssertEqual(call("isFeatureEnabled", ["key": "unknown"]) as? Bool, false)
    XCTAssertEqual((call("isFeatureEnabled") as? FlutterError)?.code, "invalid_argument")
  }

  /// Core methods incl. the internal Engage ones (`getRequestContext`, `reportServerError`).
  /// Referral links/stats, leaderboards, codes and sharing are in the Engage features (package:clikgate_flutter/engage.dart, pure Dart).
  func testCoreMethodsAreRoutedAndNeedConfigure() {
    let methods: [(String, [String: Any])] = [
      ("referrals.applyCode", ["programId": "rpg_1", "code": "ADA42"]),
      ("referrals.referredBy", [:]),
      ("getRequestContext", [:]),
      ("reportServerError", ["code": "feature_disabled", "feature": "leaderboards"]),
    ]
    for (method, args) in methods {
      let r = call(method, args)
      XCTAssertFalse(r as AnyObject === FlutterMethodNotImplemented, method)
      XCTAssertEqual((r as? FlutterError)?.code, "not_configured", method)
    }
  }

  func testErrorDetailsCarryFeatureAndOfflineTouchId() {
    let disabled = ClikgateFlutterPlugin.flutterError(
      ClikgateError(code: "feature_disabled", message: "off", feature: "leaderboards"))
    let d = disabled.details as? [String: Any]
    XCTAssertEqual(disabled.code, "feature_disabled")
    XCTAssertEqual(d?["feature"] as? String, "leaderboards")
    XCTAssertTrue(d?["status"] is NSNull)

    let referral = ClikgateFlutterPlugin.flutterError(
      ClikgateError(code: "already_referred", message: "x", status: 409, offlineTouchId: "oft_1"))
    let rd = referral.details as? [String: Any]
    XCTAssertEqual(rd?["offlineTouchId"] as? String, "oft_1")
    XCTAssertEqual(rd?["status"] as? Int, 409)
    XCTAssertNil(rd?["feature"])
  }

  /// `automaticPushToken`: the APNs token from the app delegate callback goes to the SDK unless the option is
  /// off or Dart passed its own token (e.g. FCM from firebase_messaging).
  func testAPNsTokenForwardingFollowsAutomaticPushTokenAndManualTokens() {
    XCTAssertTrue(ClikgateFlutterPlugin.forwardsAPNsToken(automatic: true, manualToken: false))
    XCTAssertFalse(ClikgateFlutterPlugin.forwardsAPNsToken(automatic: false, manualToken: false))
    XCTAssertFalse(ClikgateFlutterPlugin.forwardsAPNsToken(automatic: true, manualToken: true))
  }

  /// The plugin is an application delegate so it receives
  /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`; before configure it does nothing.
  func testDeviceTokenCallbackBeforeConfigureIsIgnored() {
    let plugin = ClikgateFlutterPlugin()
    plugin.application(UIApplication.shared, didRegisterForRemoteNotificationsWithDeviceToken: Data([0xab, 0xcd]))
    XCTAssertFalse(UserDefaults.standard.bool(forKey: ClikgateFlutterPlugin.manualPushTokenKey))
  }

  // MARK: - Engage share.system / share.whatsApp (`com.clikgate/engage` shareText / openUrl, no share_plus / url_launcher)

  @MainActor private final class FakeUI: EngageBridgeUI {
    var opened: [URL] = []
    var openResult = true
    var shared: [(String, String?)] = []
    var canPresent = true

    func open(_ url: URL, completion: @escaping (Bool) -> Void) {
      opened.append(url)
      completion(openResult)
    }

    func presentShareSheet(text: String, subject: String?) -> Bool {
      shared.append((text, subject))
      return canPresent
    }
  }

  @MainActor private func engage(_ ui: FakeUI, _ method: String, _ args: [String: Any?]) -> Any? {
    let bridge = EngageShareBridge(ui: ui)
    let done = expectation(description: method)
    var value: Any?
    bridge.handle(FlutterMethodCall(methodName: method, arguments: args.mapValues { $0 ?? NSNull() })) { r in
      value = r
      done.fulfill()
    }
    waitForExpectations(timeout: 2)
    return value
  }

  @MainActor func testOpenUrlAnswersTheOpenResult() {
    let ui = FakeUI()
    XCTAssertEqual(engage(ui, "openUrl", ["url": "whatsapp://send?text=a%26b"]) as? Bool, true)
    XCTAssertEqual(ui.opened.map(\.absoluteString), ["whatsapp://send?text=a%26b"])
    ui.openResult = false
    XCTAssertEqual(engage(ui, "openUrl", ["url": "whatsapp://send?text=x"]) as? Bool, false)
    XCTAssertEqual((engage(ui, "openUrl", [:]) as? FlutterError)?.code, "invalid_argument")
  }

  @MainActor func testShareTextPresentsTheSheetOrShareUnavailable() {
    let ui = FakeUI()
    XCTAssertNil(engage(ui, "shareText", ["text": "Join me", "subject": "MyApp"]))
    XCTAssertEqual(ui.shared.first?.0, "Join me")
    XCTAssertEqual(ui.shared.first?.1, "MyApp")
    XCTAssertNil(engage(ui, "shareText", ["text": "hi", "subject": nil]))
    XCTAssertNil(ui.shared.last?.1)
    ui.canPresent = false
    XCTAssertEqual((engage(ui, "shareText", ["text": "hi"]) as? FlutterError)?.code, "share_unavailable")
    XCTAssertEqual((engage(ui, "shareText", [:]) as? FlutterError)?.code, "invalid_argument")
    XCTAssertTrue(engage(ui, "nope", [:]) as AnyObject === FlutterMethodNotImplemented)
  }

  @MainActor func testShareItemCarriesTheSubject() {
    let item = ShareTextItem(text: "Join me", subject: "MyApp")
    let sheet = UIActivityViewController(activityItems: [], applicationActivities: nil)
    XCTAssertEqual(item.activityViewController(sheet, itemForActivityType: .mail) as? String, "Join me")
    XCTAssertEqual(item.activityViewController(sheet, subjectForActivityType: .mail), "MyApp")
  }
}
