import Foundation
import UIKit
#if canImport(ClikgateEngage)
import Clikgate
import ClikgateEngage
#else
import Clikgate // CocoaPods: the Engage subspec is compiled into the Clikgate module
#endif

/// `shareLink` for the `ClikgateEngage` TurboModule: forwards to the native Engage add-on, which
/// gives each app its own version of the link and records the share.
@objc(ClikgateEngageRN)
public final class ClikgateEngageRN: NSObject {
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
