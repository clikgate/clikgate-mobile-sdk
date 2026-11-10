import Foundation
#if !CLIKGATE_POD_SINGLE_MODULE
@_spi(ClikgateEngage) import Clikgate
#endif

/// Clikgate Engage add-on: convenience reads and actions for apps **without their own
/// backend** — the user's referral link and stats, leaderboards, promo / offline codes and share
/// helpers. Apps with a backend should call the Clikgate control-plane API from their server and
/// render their own screens instead (the recommended path, see `docs/engage.md`).
///
/// ```swift
/// let link = try await ClikgateEngage.referrals.createLink(programId: "rpg_...", displayName: "Ada")
/// let opened = try await ClikgateEngage.share.whatsApp(text: "Join me on MyApp: \(link.url)")
/// let page = try await ClikgateEngage.leaderboards.top(id: "lb_...", period: .current, limit: 50)
/// let redemption = try await ClikgateEngage.codes.redeem("LAGOS50")
/// ```
///
/// Engage keeps no attribution state: every call uses the core SDK's request context
/// (`Clikgate.configure` must have run and the first `/install` must have completed).
///
/// Rules (17A.3): every call checks `Clikgate.shared.isFeatureEnabled(_:)` first and fails with
/// `feature_disabled` without a network call; calls that act for a user fail with `not_identified`
/// until `Clikgate.shared.identifyUser(label:customerId:identityToken:)` was called (and with the server's
/// `identity_required` when the program requires a verified identity token); read results are cached
/// in memory for 60 s (never on disk); a network error is retried once, nothing else is retried;
/// errors are ``ClikgateError``s. Engage has no UI components.
public enum ClikgateEngage {
    /// Version of the Engage add-on.
    public static var version: String { "2.0.0" }

    /// The user's referral link and stats (feature `referrals`).
    public static let referrals = ClikgateEngageReferrals(client: .live)
    /// System share sheet and WhatsApp share helpers (no network).
    public static let share = ClikgateEngageShare()
    /// Leaderboards published to the SDK (feature `leaderboards`).
    public static let leaderboards = ClikgateEngageLeaderboards(client: .live)
    /// Promo / offline code redemption (feature `offline_codes`).
    public static let codes = ClikgateEngageCodes(client: .live)

    /// Drops every cached read result (e.g. after the app changed something server-side).
    public static func clearCache() {
        EngageClient.live.clearCache()
    }
}

// MARK: - Error codes used only by Engage

extension ClikgateError {
    /// `share.system` / `share.whatsApp`: nothing to present the share sheet from.
    public static var shareUnavailable: String { "share_unavailable" }
    /// `leaderboards.hostedPageUrl`: the server returned no `embed_url` (older server).
    public static var hostedPageUnavailable: String { "hosted_page_unavailable" }
    public static var clientLinkCreationDisabled: String { "client_link_creation_disabled" }
    public static var referralLinkLimit: String { "referral_link_limit" }
    public static var referrerNotFound: String { "referrer_not_found" }
    public static var leaderboardNotFound: String { "leaderboard_not_found" }
    public static var periodNotFound: String { "period_not_found" }
    public static var invalidSegment: String { "invalid_segment" }
    public static var codeExpired: String { "code_expired" }
    public static var codeDisabled: String { "code_disabled" }
    public static var redemptionLimitReached: String { "redemption_limit_reached" }
}

// MARK: - Host (the core SDK) and transport, replaceable in tests

/// What Engage needs from the core SDK.
protocol EngageHost: Sendable {
    func isFeatureEnabled(_ key: String) -> Bool
    func requestContext() async throws -> ClikgateRequestContext
    func reportServerError(code: String, feature: String?)
}

struct LiveEngageHost: EngageHost {
    func isFeatureEnabled(_ key: String) -> Bool { Clikgate.shared.isFeatureEnabled(key) }
    func requestContext() async throws -> ClikgateRequestContext { try await Clikgate.shared.requestContext() }
    func reportServerError(code: String, feature: String?) { Clikgate.shared.reportServerError(code: code, feature: feature) }
}

protocol EngageTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct EngageURLSessionTransport: EngageTransport {
    let session: URLSession

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { c in
            session.dataTask(with: request) { d, r, e in
                if let e = e { c.resume(throwing: e) } else { c.resume(returning: (d ?? Data(), r ?? URLResponse())) }
            }.resume()
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }
}

/// Runs `work` and hands the result to `completion` on the main actor.
enum EngageAsync {
    @_semantics("optimize.sil.specialize.generic.never")
    static func run<T: Sendable>(_ completion: @escaping @MainActor @Sendable (Result<T, ClikgateError>) -> Void,
                                 _ work: @escaping @Sendable () async throws -> T) {
        Task {
            let result: Result<T, ClikgateError>
            do { result = .success(try await work()) } catch let e as ClikgateError { result = .failure(e) } catch {
                result = .failure(ClikgateError(code: ClikgateError.networkError, message: error.localizedDescription))
            }
            await MainActor.run { completion(result) }
        }
    }

    static func invalid(_ message: String, param: String) -> ClikgateError {
        ClikgateError(code: ClikgateError.invalidArgument, message: message, param: param)
    }
}
