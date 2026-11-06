import Foundation
import UIKit
#if !CLIKGATE_POD_SINGLE_MODULE
@_spi(ClikgateEngage) import Clikgate
#endif

/// Share helpers (`ClikgateEngage.share`).
///
/// `link` / `referralLink` share a Clikgate link: each app Clikgate knows gets its own version of the
/// link (a short ending that tells Clikgate where it was shared; iOS asks for the item per app), other
/// apps get the plain link, and the share is recorded with `POST /v1/share-events` (the app and the
/// link, no personal data; a share count, never a click). `system` / `whatsApp` share plain text and
/// record nothing.
///
/// `whatsApp` opens `whatsapp://send?text=…` when `canOpenURL` allows it. `canOpenURL` only
/// answers for `whatsapp` when the app lists it in `LSApplicationQueriesSchemes` (Info.plist);
/// without that entry the share sheet (which also offers WhatsApp) is used.
public final class ClikgateEngageShare: @unchecked Sendable {
    /// Opens URLs / presents the share sheet (replaced in tests). Used on the main actor only.
    var ui: any EngageShareUI = LiveEngageShareUI()
    /// Sends share events (replaced in tests).
    var client: EngageClient = .live

    init() {}

    /// Presents the system share sheet with `text` from `presenter` (default: the top view
    /// controller of the foreground window). Throws `share_unavailable` when there is nothing to
    /// present from.
    @MainActor
    public func system(text: String, from presenter: UIViewController? = nil) throws {
        guard ui.presentShareSheet(items: [text], from: presenter, done: nil) else {
            throw ClikgateError(code: ClikgateError.shareUnavailable, message: "No view controller to present the share sheet from")
        }
    }

    /// Shares `text` straight into WhatsApp when it is installed (and listed in
    /// `LSApplicationQueriesSchemes`), else presents the share sheet.
    /// - Returns: `true` when WhatsApp itself was opened, `false` when the share sheet was used.
    @MainActor
    public func whatsApp(text: String, from presenter: UIViewController? = nil) async throws -> Bool {
        if let url = Self.whatsAppURL(text: text), ui.canOpen(url), await ui.open(url) {
            return true
        }
        try system(text: text, from: presenter)
        return false
    }

    /// Completion-handler variant of ``whatsApp(text:from:)`` (main thread).
    @MainActor
    public func whatsApp(text: String, from presenter: UIViewController? = nil,
                         completion: (@MainActor @Sendable (Result<Bool, ClikgateError>) -> Void)?) {
        Task { @MainActor [weak presenter] in
            let result: Result<Bool, ClikgateError>
            do { result = .success(try await self.whatsApp(text: text, from: presenter)) } catch let e as ClikgateError {
                result = .failure(e)
            } catch {
                result = .failure(ClikgateError(code: ClikgateError.shareUnavailable, message: error.localizedDescription))
            }
            completion?(result)
        }
    }

    /// `whatsapp://send?text=<percent-encoded text>` (RFC 3986 unreserved characters kept, so
    /// `&`, `=`, `+`, `#`, `?` and spaces in the text are encoded).
    static func whatsAppURL(text: String) -> URL? {
        var unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        unreserved.insert(charactersIn: "-._~")
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "whatsapp://send?text=\(encoded)")
    }
}

/// UI side of the share helpers (a protocol so tests can replace it).
@MainActor
protocol EngageShareUI {
    func canOpen(_ url: URL) -> Bool
    func open(_ url: URL) async -> Bool
    /// Presents a share sheet; false when there's no view controller to present from. `done` gets
    /// the activity type and `completed` when the sheet finishes.
    func presentShareSheet(items: [Any], from presenter: UIViewController?, done: ((String?, Bool) -> Void)?) -> Bool
}

struct LiveEngageShareUI: EngageShareUI {
    nonisolated init() {}

    func canOpen(_ url: URL) -> Bool { UIApplication.shared.canOpenURL(url) }

    func open(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url, options: [:])
    }

    func presentShareSheet(items: [Any], from presenter: UIViewController?, done: ((String?, Bool) -> Void)?) -> Bool {
        guard let vc = presenter ?? Self.topViewController() else { return false }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let done = done { sheet.completionWithItemsHandler = { type, completed, _, _ in done(type?.rawValue, completed) } }
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
        while let presented = vc?.presentedViewController, !presented.isBeingDismissed { vc = presented }
        return vc
    }
}

// MARK: - share.link

extension ClikgateEngageShare {
    /// Shares a Clikgate link (`url`, e.g. `https://inv.myapp.com/summer`) with an optional `message`
    /// in front of it.
    ///
    /// Without `app`, opens the share menu: each app Clikgate knows gets its own version of the link,
    /// other apps the plain link, and the app the person picks is recorded when iOS reports it. With
    /// `app`, opens that app where iOS can (WhatsApp, Telegram, X, Mail), else the share menu.
    /// `shareUrls`: the link's `share_urls` object from your backend (the Clikgate API's link object,
    /// keyed by app such as `"whatsapp"`), used as it is.
    /// - Returns: `true` when `app` itself was opened, `false` when the share menu was shown.
    /// - Throws: `share_unavailable` when there is nothing to present the menu from.
    @MainActor @discardableResult
    public func link(_ url: String, message: String? = nil, app: ClikgateShareApp? = nil,
                     shareUrls: [String: String]? = nil, from presenter: UIViewController? = nil) async throws -> Bool {
        try await share(EngageShareLink(url, nil, shareUrls, message), app, presenter)
    }

    /// ``link(_:message:app:shareUrls:from:)`` for the user's referral link: each app's version keeps
    /// the referral code, so the referrer is still credited.
    @MainActor @discardableResult
    public func referralLink(_ link: ClikgateReferralLink, message: String? = nil, app: ClikgateShareApp? = nil,
                             from presenter: UIViewController? = nil) async throws -> Bool {
        try await share(EngageShareLink(link.url, link.code, nil, message), app, presenter)
    }

    @MainActor
    func share(_ link: EngageShareLink, _ app: ClikgateShareApp?, _ presenter: UIViewController?) async throws -> Bool {
        let client = self.client
        if let app = app, let url = link.directURL(app), app != .whatsapp || ui.canOpen(url), await ui.open(url) {
            Self.record(client, link.urlFor(app), app)
            return true
        }
        let shown = ui.presentShareSheet(items: [link], from: presenter) { type, completed in
            // "Share started with app X": `completed` isn't reliable for every app (WhatsApp reports it after a cancel too).
            guard completed, let type = type else { return }
            let picked = EngageShareLink.app(type)
            Self.record(client, link.urlFor(picked), picked)
        }
        if !shown {
            throw ClikgateError(code: ClikgateError.shareUnavailable, message: "No view controller to present the share sheet from")
        }
        return false
    }

    /// `POST /v1/share-events` with the SDK key (no feature switch; failures are dropped).
    static func record(_ client: EngageClient, _ url: String, _ app: ClikgateShareApp) {
        let body: [String: Any] = ["url": url, "app": app.rawValue]
        Task { _ = try? await client.call(feature: "", method: "POST", path: "/v1/share-events", body: body, needsUser: false, cacheable: false) }
    }
}

/// One link being shared: the item iOS asks for per activity type.
final class EngageShareLink: NSObject, UIActivityItemSource {
    let url: String, code: String?, given: [String: String]?, message: String

    init(_ url: String, _ code: String?, _ given: [String: String]?, _ message: String?) {
        self.url = url; self.code = code; self.given = given
        self.message = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func activityViewControllerPlaceholderItem(_ c: UIActivityViewController) -> Any { text(nil) }

    func activityViewController(_ c: UIActivityViewController, itemForActivityType t: UIActivity.ActivityType?) -> Any? {
        text(Self.app(t?.rawValue))
    }

    func urlFor(_ app: ClikgateShareApp?) -> String {
        if let a = app, let u = given?[a.rawValue] { return u }
        return Self.withEnding(url, app, code)
    }


    func text(_ app: ClikgateShareApp?) -> String { message.isEmpty ? urlFor(app) : message + " " + urlFor(app) }

    /// A documented URL that opens `app` with the text; nil for apps without one.
    func directURL(_ app: ClikgateShareApp) -> URL? {
        let u = Self.enc(urlFor(app)), m = Self.enc(message)
        switch app {
        case .whatsapp: return ClikgateEngageShare.whatsAppURL(text: text(app))
        case .telegram: return URL(string: "https://t.me/share/url?url=" + u + "&text=" + m)
        case .x: return URL(string: "https://x.com/intent/tweet?url=" + u + "&text=" + m)
        case .email: return URL(string: "mailto:?body=" + Self.enc(text(app)))
        default: return nil
        }
    }

    static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? ""
    }

    /// The app behind an activity type: Messages, Mail, else the app whose bundle ID the type starts with.
    static func app(_ type: String?) -> ClikgateShareApp {
        guard let t = type?.lowercased() else { return .other }
        if t == "com.apple.uikit.activity.message" { return .sms }
        if t == "com.apple.uikit.activity.mail" { return .email }
        for (id, app) in EngageShareTargets.bundles where t == id || t.hasPrefix(id + ".") {
            return ClikgateShareApp(rawValue: app) ?? .other
        }
        return .other
    }

    /// `url` with `app`'s ending (none for apps without one), replacing an ending it already has. A
    /// referral `code` in the query (`?ref=CODE`) gets it; otherwise the last path segment does. URLs
    /// that aren't http(s) or have no path come back unchanged.
    static func withEnding(_ url: String, _ app: ClikgateShareApp?, _ code: String?) -> String {
        let suffix = app.flatMap { EngageShareTargets.endings[$0.rawValue] }.map { "-" + $0 } ?? ""
        let ending = "(?:-(?:[A-Za-z]|[qQ][0-9]+))?"
        if let code = code {
            let inQuery = "^([hH][tT][tT][pP][sS]?://[^?#]*\\?(?:[^#]*&)?[^=&#]+=)" + NSRegularExpression.escapedPattern(for: code)
                + ending + "(?=[&#]|$)"
            let r = url.replacingOccurrences(of: inQuery, with: "$1" + code + suffix, options: .regularExpression)
            if r != url || url.range(of: inQuery, options: .regularExpression) != nil { return r }
        }
        let inPath = "^([hH][tT][tT][pP][sS]?://[^/?#]+(?:/[^?#]*)?/)([^/?#]+?)" + ending + "/*([?#].*)?$"
        return url.replacingOccurrences(of: inPath, with: "$1$2" + suffix + "$3", options: .regularExpression)
    }

}
