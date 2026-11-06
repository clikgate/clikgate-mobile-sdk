import Flutter
import UIKit
import XCTest
import Clikgate

@testable import clikgate_flutter

/// Unit tests of the plugin's Swift side (method routing and error details). The Clikgate SDK is not
/// configured in the test host, so calls that need it answer `not_configured`.
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
  /// Referral links/stats, leaderboards, codes and sharing are in clikgate_engage (pure Dart).
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
}
