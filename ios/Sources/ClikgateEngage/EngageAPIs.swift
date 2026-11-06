import Foundation
#if !CLIKGATE_POD_SINGLE_MODULE
@_spi(ClikgateEngage) import Clikgate
#endif

private let referralsFeature = "referrals"
private let leaderboardsFeature = "leaderboards"
private let codesFeature = "offline_codes"

private func requireNonBlank(_ value: String, _ name: String, param: String) throws {
    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw EngageAsync.invalid("\(name) is required", param: param)
    }
}

// MARK: - Referrals

/// The user's referral link and stats (`ClikgateEngage.referrals`, feature `referrals`). Both
/// calls need an identified user (`not_identified` otherwise) and, when the program requires it, a
/// verified identity token (`identity_required` from the server).
public final class ClikgateEngageReferrals: Sendable {
    let client: EngageClient

    init(client: EngageClient) { self.client = client }

    /// Gets or creates the current user's referral link and code (`POST /v1/sdk/referrals/link`,
    /// idempotent per program and user). Errors include `client_link_creation_disabled` and
    /// `referral_link_limit`.
    public func createLink(programId: String, displayName: String? = nil) async throws -> ClikgateReferralLink {
        try requireNonBlank(programId, "programId", param: "program_id")
        var body: [String: Any] = ["program_id": programId]
        if let d = displayName { body["display_name"] = d }
        return try EngageClient.decode(await client.call(feature: referralsFeature, method: "POST", path: "v1/sdk/referrals/link", body: body,
                                     needsUser: true, cacheable: false), ClikgateReferralLink.init(json:))
    }

    /// The current user's code, link and stats (`GET /v1/sdk/referrals/me`; cached 60 s).
    /// `referrer_not_found` until the user has a link in the program.
    public func myStats(programId: String) async throws -> ClikgateReferralStats {
        try requireNonBlank(programId, "programId", param: "program_id")
        return try EngageClient.decode(await client.call(feature: referralsFeature, method: "GET", path: "v1/sdk/referrals/me",
                                     query: [URLQueryItem(name: "program_id", value: programId)],
                                     needsUser: true, cacheable: true), ClikgateReferralStats.init(json:))
    }

    public func createLink(programId: String, displayName: String? = nil,
                           completion: @escaping @MainActor @Sendable (Result<ClikgateReferralLink, ClikgateError>) -> Void) {
        EngageAsync.run(completion) { try await self.createLink(programId: programId, displayName: displayName) }
    }

    public func myStats(programId: String,
                        completion: @escaping @MainActor @Sendable (Result<ClikgateReferralStats, ClikgateError>) -> Void) {
        EngageAsync.run(completion) { try await self.myStats(programId: programId) }
    }
}

// MARK: - Leaderboards

/// Leaderboards published to the SDK (`visibility = sdk`): `ClikgateEngage.leaderboards`
/// (feature `leaderboards`). `top` needs only a completed install; `me`, `aroundMe`, `setOptOut`
/// and `hostedPageUrl` also an identified user. Errors: `leaderboard_not_found`,
/// `referrer_not_found`, `period_not_found`, `invalid_segment`, `not_identified`,
/// `identity_required`, `identity_invalid`, `rate_limited`, ...
public final class ClikgateEngageLeaderboards: Sendable {
    let client: EngageClient

    init(client: EngageClient) { self.client = client }

    /// Top entries of a board (cached 60 s). `limit` is clamped to 1...100.
    public func top(id: String, period: ClikgateLeaderboardPeriodSelector = .current, segment: String? = nil,
                    limit: Int = 50) async throws -> ClikgateLeaderboardPage {
        try Self.validate(id: id, period: period)
        let q = Self.query([("period", period.rawValue), ("segment", segment), ("limit", String(min(100, max(1, limit))))])
        return try EngageClient.decode(await client.call(feature: leaderboardsFeature, method: "GET", path: Self.path(id), query: q,
                                     needsUser: false, cacheable: true), ClikgateLeaderboardPage.init(json:))
    }

    /// The current user's rank, score, pending count, gap to the next rank and period end (cached 60 s).
    public func me(id: String, period: ClikgateLeaderboardPeriodSelector = .current,
                   segment: String? = nil) async throws -> ClikgateMyRank {
        try Self.validate(id: id, period: period)
        return try EngageClient.decode(await client.call(feature: leaderboardsFeature, method: "GET", path: Self.path(id, "me"),
                                     query: Self.query([("period", period.rawValue), ("segment", segment)]),
                                     needsUser: true, cacheable: true), ClikgateMyRank.init(json:))
    }

    /// Up to `radius` entries above and below the current user (clamped to 1...25; cached 60 s).
    public func aroundMe(id: String, radius: Int = 5, period: ClikgateLeaderboardPeriodSelector = .current,
                         segment: String? = nil) async throws -> ClikgateLeaderboardPage {
        try Self.validate(id: id, period: period)
        let q = Self.query([("radius", String(min(25, max(1, radius)))), ("period", period.rawValue), ("segment", segment)])
        return try EngageClient.decode(await client.call(feature: leaderboardsFeature, method: "GET", path: Self.path(id, "around-me"), query: q,
                                     needsUser: true, cacheable: true), ClikgateLeaderboardPage.init(json:))
    }

    /// Hides (`optOut: true`) or shows the current user on every board of a referral program.
    public func setOptOut(programId: String, optOut: Bool) async throws {
        try requireNonBlank(programId, "programId", param: "program_id")
        _ = try await client.call(feature: leaderboardsFeature, method: "POST", path: "v1/sdk/leaderboards/opt-out",
                                  body: ["program_id": programId, "opt_out": optOut],
                                  needsUser: true, cacheable: false)
    }

    /// A signed, short-lived URL of the hosted leaderboard page that highlights the
    /// current user, for a web view (`GET .../me?embed=1` → `embed_url`; never cached).
    /// `hosted_page_unavailable` when the server returns no URL.
    public func hostedPageUrl(id: String, period: ClikgateLeaderboardPeriodSelector = .current) async throws -> URL {
        try Self.validate(id: id, period: period)
        let rank = try EngageClient.decode(await client.call(feature: leaderboardsFeature, method: "GET", path: Self.path(id, "me"),
                                         query: Self.query([("period", period.rawValue), ("embed", "1")]),
                                         needsUser: true, cacheable: false), ClikgateMyRank.init(json:))
        guard let url = rank.embedUrl else {
            throw ClikgateError(code: ClikgateError.hostedPageUnavailable, message: "The server returned no hosted page URL.")
        }
        return url
    }

    // MARK: Completion-handler variants (main thread)

    public func top(id: String, period: ClikgateLeaderboardPeriodSelector = .current, segment: String? = nil, limit: Int = 50,
                    completion: @escaping @MainActor @Sendable (Result<ClikgateLeaderboardPage, ClikgateError>) -> Void) {
        EngageAsync.run(completion) { try await self.top(id: id, period: period, segment: segment, limit: limit) }
    }

    public func me(id: String, period: ClikgateLeaderboardPeriodSelector = .current, segment: String? = nil,
                   completion: @escaping @MainActor @Sendable (Result<ClikgateMyRank, ClikgateError>) -> Void) {
        EngageAsync.run(completion) { try await self.me(id: id, period: period, segment: segment) }
    }

    public func aroundMe(id: String, radius: Int = 5, period: ClikgateLeaderboardPeriodSelector = .current, segment: String? = nil,
                         completion: @escaping @MainActor @Sendable (Result<ClikgateLeaderboardPage, ClikgateError>) -> Void) {
        EngageAsync.run(completion) { try await self.aroundMe(id: id, radius: radius, period: period, segment: segment) }
    }

    public func setOptOut(programId: String, optOut: Bool,
                          completion: (@MainActor @Sendable (Result<Void, ClikgateError>) -> Void)? = nil) {
        EngageAsync.run({ r in completion?(r) }) { try await self.setOptOut(programId: programId, optOut: optOut) }
    }

    public func hostedPageUrl(id: String, period: ClikgateLeaderboardPeriodSelector = .current,
                              completion: @escaping @MainActor @Sendable (Result<URL, ClikgateError>) -> Void) {
        EngageAsync.run(completion) { try await self.hostedPageUrl(id: id, period: period) }
    }

    // MARK: Helpers

    private static func validate(id: String, period: ClikgateLeaderboardPeriodSelector) throws {
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || id.contains("/") {
            throw EngageAsync.invalid("The leaderboard id is required", param: "leaderboard_id")
        }
        try requireNonBlank(period.rawValue, "period", param: "period")
    }

    static func path(_ id: String, _ suffix: String? = nil) -> String {
        "v1/sdk/leaderboards/\(id)" + (suffix.map { "/\($0)" } ?? "")
    }

    private static func query(_ items: [(String, String?)]) -> [URLQueryItem] {
        var out: [URLQueryItem] = []
        for (k, v) in items { if let v = v { out.append(URLQueryItem(name: k, value: v)) } }
        return out
    }
}

// MARK: - Codes

/// Promo / offline code redemption (`ClikgateEngage.codes`, feature `offline_codes`): a code seen
/// on a poster, a flyer, a USSD menu or given by an agent, typed into the app. Errors:
/// `code_not_found`, `code_expired`, `code_disabled`, `redemption_limit_reached`, `rate_limited`
/// (5 per hour per installation) and, for referral codes, the referral errors of `applyCode` with
/// ``ClikgateError/offlineTouchId`` set (the touch is still recorded).
public final class ClikgateEngageCodes: Sendable {
    let client: EngageClient

    init(client: EngageClient) { self.client = client }

    /// Redeems `code` (trimmed, 3–30 characters; the server ignores case, spaces and dashes).
    public func redeem(_ code: String) async throws -> ClikgateRedemption {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...30).contains(trimmed.count) else {
            throw EngageAsync.invalid("The code must be 3-30 characters", param: "code")
        }
        return try EngageClient.decode(await client.call(feature: codesFeature, method: "POST", path: "v1/sdk/codes/redeem", body: ["code": trimmed],
                                     needsUser: false, cacheable: false), ClikgateRedemption.init(json:))
    }

    public func redeem(_ code: String, completion: @escaping @MainActor @Sendable (Result<ClikgateRedemption, ClikgateError>) -> Void) {
        EngageAsync.run(completion) { try await self.redeem(code) }
    }
}
