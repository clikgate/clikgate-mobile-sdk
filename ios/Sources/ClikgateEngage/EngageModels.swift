import Foundation
#if !CLIKGATE_POD_SINGLE_MODULE
@_spi(ClikgateEngage) import Clikgate
#endif

/// The current user's referral link in a program (``ClikgateEngageReferrals/createLink(programId:displayName:)``).
public struct ClikgateReferralLink: Sendable {
    public let referrerId: String
    public let programId: String
    public let code: String
    public let url: String
    public let shortUrl: String?

    /// A referral link you already have (for example from your backend or the Flutter / React Native bridges).
    public init(referrerId: String, programId: String, code: String, url: String, shortUrl: String?) {
        self.referrerId = referrerId; self.programId = programId; self.code = code; self.url = url; self.shortUrl = shortUrl
    }

    init?(json j: EngageJSON) {
        guard let code = j.str("code"), let url = j.str("url") else { return nil }
        referrerId = j.str("referrer_id") ?? ""
        programId = j.str("program_id") ?? ""
        self.code = code
        self.url = url
        shortUrl = j.str("short_url")
    }
}

/// The current user's referrer stats in a program (no referee personal data).
public struct ClikgateReferralStats: Sendable {
    public let referrerId: String
    public let programId: String
    public let code: String
    public let url: String
    public let shortUrl: String?
    /// `active` or `blocked`.
    public let status: String
    public let clicks: Int
    public let installs: Int
    public let signups: Int
    public let inProgress: Int
    public let qualified: Int
    public let disqualified: Int
    public let rejected: Int

    @_optimize(size)
    init?(json j: EngageJSON) {
        guard let code = j.str("code") else { return nil }
        referrerId = j.str("referrer_id") ?? ""
        programId = j.str("program_id") ?? ""
        self.code = code
        url = j.str("url") ?? ""
        shortUrl = j.str("short_url")
        status = j.str("status") ?? "active"
        let s = j.obj("stats") ?? EngageJSON(object: [:])
        clicks = s.int("clicks") ?? 0; installs = s.int("installs") ?? 0; signups = s.int("signups") ?? 0
        inProgress = s.int("in_progress") ?? 0; qualified = s.int("qualified") ?? 0
        disqualified = s.int("disqualified") ?? 0; rejected = s.int("rejected") ?? 0
    }
}

/// Selects the period of a leaderboard call: ``current`` (default), ``previous`` or a period key
/// such as `2026-W43` (`.key("2026-W43")`, or a string literal).
public struct ClikgateLeaderboardPeriodSelector: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    /// The `period` query value.
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    /// The running period.
    public static let current = ClikgateLeaderboardPeriodSelector(rawValue: "current")
    /// The period before the running one.
    public static let previous = ClikgateLeaderboardPeriodSelector(rawValue: "previous")
    /// A specific period by key (`2026-W43`, `2026-10`, ...).
    public static func key(_ key: String) -> ClikgateLeaderboardPeriodSelector { .init(rawValue: key) }
}

/// A leaderboard period as returned by the API.
public struct ClikgateLeaderboardPeriod: Sendable {
    /// e.g. `2026-W43`.
    public let key: String
    /// `open`, `closed_provisional` or `final`.
    public let status: String
    /// The server's timestamp strings (ISO 8601 UTC).
    public let startsAtRaw: String?
    public let endsAtRaw: String?

    public var startsAt: Date? { EngageDates.parse(startsAtRaw) }
    public var endsAt: Date? { EngageDates.parse(endsAtRaw) }

    init(json j: EngageJSON?) {
        key = j?.str("key") ?? ""
        status = j?.str("status") ?? "open"
        startsAtRaw = j?.str("starts_at")
        endsAtRaw = j?.str("ends_at")
    }
}

/// One ranked referrer. `display` follows the board's name mode (masked, display name or code);
/// customer user ids and referee data are never returned.
public struct ClikgateLeaderboardEntry: Sendable {
    public let rank: Int
    public let referrerId: String
    public let display: String
    public let score: Int
    /// Not-yet-qualified count; nil when the board hides it.
    public let pending: Int?
    /// True for the current user's own entry.
    public let isMe: Bool

    init(json j: EngageJSON) {
        rank = j.int("rank") ?? 0
        referrerId = j.str("referrer_id") ?? ""
        display = j.str("display") ?? ""
        score = j.int("score") ?? 0
        pending = j.int("pending")
        isMe = j.bool("is_me") ?? false
    }
}

/// A page of leaderboard entries (`top` or `aroundMe`). `name`, `metric` and `segment` are nil for
/// `aroundMe` (the API sends only the id, period and entries there).
public struct ClikgateLeaderboardPage: Sendable {
    public let leaderboardId: String
    public let name: String?
    /// `qualified`, `installs`, `signups`, `step` or `points`.
    public let metric: String?
    public let segment: String?
    public let period: ClikgateLeaderboardPeriod
    public let entries: [ClikgateLeaderboardEntry]

    @_optimize(size)
    init?(json j: EngageJSON) {
        guard let id = j.str("leaderboard_id") else { return nil }
        leaderboardId = id
        name = j.str("name")
        metric = j.str("metric")
        segment = j.str("segment")
        period = ClikgateLeaderboardPeriod(json: j.obj("period"))
        entries = j.objects("entries").map(ClikgateLeaderboardEntry.init(json:))
    }
}

/// The current user's standing on a leaderboard (`me`).
public struct ClikgateMyRank: Sendable {
    public let leaderboardId: String
    public let period: ClikgateLeaderboardPeriod
    public let referrerId: String
    /// nil when the user has no score yet, opted out, or is below the board's minimum score.
    public let rank: Int?
    public let score: Int
    public let pending: Int?
    /// Points needed to move up one rank; nil at rank 1 or when unranked.
    public let gapToNext: Int?
    public let bestRank: Int?
    /// The server's timestamp string (ISO 8601 UTC).
    public let periodEndsAtRaw: String?
    public let optedOut: Bool
    /// Signed hosted-page URL (only with `?embed=1`, i.e. ``ClikgateEngageLeaderboards/hostedPageUrl(id:period:)``).
    public let embedUrl: URL?

    public var periodEndsAt: Date? { EngageDates.parse(periodEndsAtRaw) }

    @_optimize(size)
    init?(json j: EngageJSON) {
        guard let id = j.str("leaderboard_id") else { return nil }
        leaderboardId = id
        period = ClikgateLeaderboardPeriod(json: j.obj("period"))
        referrerId = j.str("referrer_id") ?? ""
        rank = j.int("rank")
        score = j.int("score") ?? 0
        pending = j.int("pending")
        gapToNext = j.int("gap_to_next")
        bestRank = j.int("best_rank")
        periodEndsAtRaw = j.str("period_ends_at")
        optedOut = j.bool("opted_out") ?? false
        embedUrl = j.str("embed_url").flatMap(URL.init(string:))
    }
}

/// Result of ``ClikgateEngageCodes/redeem(_:)``.
public struct ClikgateRedemption: Sendable {
    /// The code a redemption matched.
    public struct RedeemedCode: Sendable {
        /// The normalised code (uppercase, no spaces or dashes).
        public let code: String
        /// `link` (promo / campaign code) or `referral` (a referrer's code).
        public let kind: String
        public let linkId: String?
        public let campaignId: String?
        public let referrerId: String?
        public let programId: String?
    }

    /// The recorded offline touch (`oft_...`).
    public let offlineTouchId: String
    public let code: RedeemedCode
    /// For a referral code redeemed by an eligible installation: the new referral (`source == "offline_code"`).
    public let referral: ClikgateReferral?

    @_optimize(size)
    init?(json j: EngageJSON) {
        guard let touch = j.str("offline_touch_id") else { return nil }
        offlineTouchId = touch
        let c = j.obj("code") ?? EngageJSON(object: [:])
        code = RedeemedCode(code: c.str("code") ?? "", kind: c.str("kind") ?? "link", linkId: c.str("link_id"),
                            campaignId: c.str("campaign_id"), referrerId: c.str("referrer_id"), programId: c.str("program_id"))
        referral = ClikgateReferral(apiJSON: j.obj("referral")?.o)
    }
}
