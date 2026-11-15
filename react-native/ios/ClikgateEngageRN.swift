import Foundation
import UIKit
#if canImport(ClikgateEngage)
@_spi(ClikgateEngage) import Clikgate
import ClikgateEngage
#else
@_spi(ClikgateEngage) import Clikgate // CocoaPods: the Engage sources are compiled into the Clikgate module
#endif

/// `shareLink` for the `ClikgateEngage` TurboModule: forwards to the native SDK's Engage features,
/// which give each app its own version of the link and record the share.
@objc(ClikgateEngageRN)
public final class ClikgateEngageRN: NSObject {
    /// Change 26, R.28: the referral link saved for the signed-in customer (`{link, token}`).
    @objc public static func savedLink(_ programId: String, resolve: @escaping (NSDictionary) -> Void) {
        _ = ClikgateEngage.referrals   // prepares links after identifyUser() from now on
        let (data, token) = Clikgate.shared.savedLinkJSON(programId: programId)
        let link: Any = data.flatMap { String(data: $0, encoding: .utf8) } ?? NSNull()
        resolve(["link": link, "token": token ?? NSNull()])
    }

    @objc public static func saveLink(_ programId: String, link: String, token: String, resolve: @escaping () -> Void) {
        if let data = link.data(using: .utf8) {
            Clikgate.shared.saveLinkJSON(programId: programId, json: data, token: token)
        }
        resolve()
    }

    @objc public static func shareLink(_ args: NSDictionary, resolve: @escaping (Bool) -> Void,
                                       reject: @escaping (String, String) -> Void) {
        guard let url = args["url"] as? String, !url.isEmpty else { return reject("invalid_argument", "url is required") }
        let message = args["message"] as? String
        let app = (args["app"] as? String).flatMap(ClikgateShareApp.init(rawValue:))
        let code = args["code"] as? String
        let shortUrl = args["shortUrl"] as? String
        let given = args["shareUrls"] as? [String: String]
        Task { @MainActor in
            do {
                if let code = code {
                    let link = ClikgateReferralLink(referrerId: "", programId: "", code: code, url: url, shortUrl: shortUrl)
                    resolve(try await ClikgateEngage.share.referralLink(link, message: message, app: app))
                } else {
                    resolve(try await ClikgateEngage.share.link(url, message: message, app: app, shareUrls: given))
                }
            } catch let e as ClikgateError {
                reject(e.code, e.message)
            } catch {
                reject("share_unavailable", error.localizedDescription)
            }
        }
    }
}
