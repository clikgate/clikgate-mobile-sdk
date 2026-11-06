import Flutter
import UIKit
#if canImport(ClikgateEngage)
import Clikgate
import ClikgateEngage
#else
import Clikgate // CocoaPods: the Engage subspec is compiled into the Clikgate module
#endif

/// iOS side of `clikgate_engage`: only `share.link` / `share.referralLink`, which need the share
/// menu. It forwards to the native Engage add-on, which gives each app its own version of the link
/// and records the share. Everything else in clikgate_engage is Dart.
public final class ClikgateEngagePlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.clikgate/engage", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(ClikgateEngagePlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "shareLink" else { return result(FlutterMethodNotImplemented) }
        let args = call.arguments as? [String: Any] ?? [:]
        guard let url = args["url"] as? String, !url.isEmpty else {
            return result(FlutterError(code: "invalid_argument", message: "url is required", details: nil))
        }
        let message = args["message"] as? String
        let app = (args["app"] as? String).flatMap(ClikgateShareApp.init(rawValue:))
        let code = args["code"] as? String
        let given = args["shareUrls"] as? [String: String]
        Task { @MainActor in
            do {
                let opened: Bool
                if let code = code {
                    let link = ClikgateReferralLink(referrerId: "", programId: "", code: code, url: url, shortUrl: args["shortUrl"] as? String)
                    opened = try await ClikgateEngage.share.referralLink(link, message: message, app: app)
                } else {
                    opened = try await ClikgateEngage.share.link(url, message: message, app: app, shareUrls: given)
                }
                result(opened)
            } catch let e as ClikgateError {
                result(FlutterError(code: e.code, message: e.message, details: nil))
            } catch {
                result(FlutterError(code: "share_unavailable", message: error.localizedDescription, details: nil))
            }
        }
    }
}
