import Flutter
import UIKit
#if canImport(ClikgateEngage)
import Clikgate
import ClikgateEngage
#else
import Clikgate // CocoaPods: the Engage sources are compiled into the Clikgate module
#endif

/// The Engage features' native side (`package:clikgate_flutter/engage.dart`), which need the share menu
/// or another app. `shareLink` (`share.link` / `share.referralLink`) forwards to the native SDK's Engage
/// features, which give each app its own version of the link and record the share. `shareText`
/// (`share.system`) and `openUrl` (`share.whatsApp`'s `whatsapp://` link) are plain UIKit here, so the
/// plugin needs no share_plus / url_launcher. Everything else in Engage is Dart. Registered by
/// ClikgateFlutterPlugin (one plugin since 2.1.0).
final class EngageShareBridge: NSObject, FlutterPlugin {
    /// Opens URLs / presents the share sheet (replaced in tests).
    let ui: EngageBridgeUI

    init(ui: EngageBridgeUI = LiveEngageBridgeUI()) {
        self.ui = ui
    }

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.clikgate/engage", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(EngageShareBridge(), channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "shareLink": shareLink(args, result)
        case "shareText": shareText(args, result)
        case "openUrl": openUrl(args, result)
        default: result(FlutterMethodNotImplemented)
        }
    }

    /// `{text, subject?}`: `UIActivityViewController` from the top view controller; `share_unavailable` when
    /// there is none.
    private func shareText(_ args: [String: Any], _ result: @escaping FlutterResult) {
        guard let text = args["text"] as? String else {
            return result(FlutterError(code: "invalid_argument", message: "text is required", details: nil))
        }
        let subject = args["subject"] as? String
        Task { @MainActor in
            if self.ui.presentShareSheet(text: text, subject: subject) {
                result(nil)
            } else {
                result(FlutterError(code: "share_unavailable", message: "No view controller to present the share sheet from", details: nil))
            }
        }
    }

    /// `{url}`: `UIApplication.open` (no `canOpenURL`, so no `LSApplicationQueriesSchemes` entry is needed);
    /// answers its completion result.
    private func openUrl(_ args: [String: Any], _ result: @escaping FlutterResult) {
        guard let s = args["url"] as? String, !s.isEmpty, let url = URL(string: s) else {
            return result(FlutterError(code: "invalid_argument", message: "url is required", details: nil))
        }
        Task { @MainActor in
            self.ui.open(url) { opened in result(opened) }
        }
    }

    private func shareLink(_ args: [String: Any], _ result: @escaping FlutterResult) {
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

/// UIKit side of `shareText` / `openUrl` (a protocol so RunnerTests can replace it). Main thread only.
@MainActor
protocol EngageBridgeUI {
    func open(_ url: URL, completion: @escaping (Bool) -> Void)
    /// False when there's no view controller to present from.
    func presentShareSheet(text: String, subject: String?) -> Bool
}

struct LiveEngageBridgeUI: EngageBridgeUI {
    nonisolated init() {}

    func open(_ url: URL, completion: @escaping (Bool) -> Void) {
        UIApplication.shared.open(url, options: [:], completionHandler: completion)
    }

    func presentShareSheet(text: String, subject: String?) -> Bool {
        guard let vc = Self.topViewController() else { return false }
        let sheet = UIActivityViewController(activityItems: [ShareTextItem(text: text, subject: subject)], applicationActivities: nil)
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = vc.view
            pop.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        vc.present(sheet, animated: true)
        return true
    }

    /// The top-most presented view controller of the foreground (else the first) window scene.
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        let scene = (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first) as? UIWindowScene
        var vc = (scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first)?.rootViewController
            ?? UIApplication.shared.delegate?.window??.rootViewController
        while let presented = vc?.presentedViewController, !presented.isBeingDismissed { vc = presented }
        return vc
    }
}

/// The shared text, plus the subject (used by Mail and other apps that ask for one).
final class ShareTextItem: NSObject, UIActivityItemSource {
    let text: String
    let subject: String?

    init(text: String, subject: String?) {
        self.text = text
        self.subject = subject
    }

    func activityViewControllerPlaceholderItem(_ c: UIActivityViewController) -> Any { text }

    func activityViewController(_ c: UIActivityViewController, itemForActivityType t: UIActivity.ActivityType?) -> Any? { text }

    func activityViewController(_ c: UIActivityViewController, subjectForActivityType t: UIActivity.ActivityType?) -> String {
        subject ?? ""
    }
}
