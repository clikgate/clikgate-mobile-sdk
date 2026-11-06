package com.clikgate.engage

import com.clikgate.Referral

// Models are plain classes (no data-class equals / hashCode / copy / componentN) to stay inside
// the 40 KB size budget; compare by the fields you need (e.g. `referrerId`, `rank`).

/** The current user's referral link and code in a program ([EngageReferrals.createLink]). */
public class ReferralLink(
    public val referrerId: String,
    public val programId: String,
    public val code: String,
    public val url: String,
    public val shortUrl: String,
)

/** The current user's referrer stats in a program ([EngageReferrals.myStats]). */
public class ReferralStats(
    public val referrerId: String,
    public val programId: String,
    public val code: String,
    public val url: String,
    public val shortUrl: String,
    /** `active` or `blocked`. */
    public val status: String,
    public val clicks: Int,
    public val installs: Int,
    public val signups: Int,
    public val inProgress: Int,
    public val qualified: Int,
    public val disqualified: Int,
    public val rejected: Int,
)

/**
 * A leaderboard period as returned by the API. To select a period in a call, pass
 * [CURRENT] (default), [PREVIOUS] or a period key such as `2026-W43`.
 */
public class LeaderboardPeriod(
    /** e.g. `2026-W43`. */
    public val key: String,
    /** `open`, `closed_provisional` or `final`. */
    public val status: String,
    /** ISO 8601 UTC. */
    public val startsAt: String?,
    /** ISO 8601 UTC. */
    public val endsAt: String?,
) {
    public companion object {
        /** The running period (`period=current`). */
        public const val CURRENT: String = "current"

        /** The period before the running one (`period=previous`). */
        public const val PREVIOUS: String = "previous"
    }
}

/** One ranked referrer. [display] follows the board's name mode (masked, display name or code). */
public class LeaderboardEntry(
    public val rank: Int,
    public val referrerId: String,
    public val display: String,
    public val score: Int,
    /** Not-yet-qualified count; null when the board hides it. */
    public val pending: Int?,
    /** True for the current user's own entry. */
    public val isMe: Boolean,
)

/**
 * A page of leaderboard entries ([EngageLeaderboards.top] or [EngageLeaderboards.aroundMe]).
 * [name], [metric] and [segment] are null for `aroundMe` (the API sends only the id, period and
 * entries there).
 */
public class LeaderboardPage(
    public val leaderboardId: String,
    public val name: String?,
    /** `qualified`, `installs`, `signups`, `step` or `points`. */
    public val metric: String?,
    public val segment: String?,
    public val period: LeaderboardPeriod,
    public val entries: List<LeaderboardEntry>,
)

/** The current user's standing on a leaderboard ([EngageLeaderboards.me]). */
public class MyRank(
    public val leaderboardId: String,
    public val period: LeaderboardPeriod,
    public val referrerId: String,
    /** Null when the user has no score yet, opted out, or is below the board's minimum score. */
    public val rank: Int?,
    public val score: Int,
    public val pending: Int?,
    /** Points needed to move up one rank; null at rank 1 or when unranked. */
    public val gapToNext: Int?,
    public val bestRank: Int?,
    /** ISO 8601 UTC. */
    public val periodEndsAt: String?,
    public val optedOut: Boolean,
    /** Signed hosted-page URL; only set by [EngageLeaderboards.hostedPageUrl]'s `?embed=1` call. */
    public val embedUrl: String? = null,
)

/** The code a [Redemption] matched. */
public class RedeemedCode(
    /** The normalised code (uppercase, no spaces or dashes). */
    public val code: String,
    /** `link` (promo / campaign code) or `referral` (a referrer's code). */
    public val kind: String,
    public val linkId: String?,
    public val campaignId: String?,
    public val referrerId: String?,
    public val programId: String?,
)

/** Result of [EngageCodes.redeem]. */
public class Redemption(
    /** The recorded offline touch (`oft_...`). */
    public val offlineTouchId: String,
    public val code: RedeemedCode,
    /** For a referral code redeemed by an eligible installation: the new referral (`source = offline_code`). */
    public val referral: Referral?,
)

/**
 * Error codes ([com.clikgate.ClikgateError.code]) specific to the Engage add-on, besides the core
 * SDK codes (`feature_disabled`, `not_configured`, `install_pending`, `network_error`, ...) and the
 * backend's referral codes.
 */
public object EngageErrors {
    /** The call acts for a user, but [com.clikgate.Clikgate.identifyUser] wasn't called (no network call made). */
    public const val NOT_IDENTIFIED: String = "not_identified"

    /** The program requires a verified identity token (from the server). */
    public const val IDENTITY_REQUIRED: String = "identity_required"

    /** No app on the device can handle a text share (not even the system chooser). */
    public const val SHARE_UNAVAILABLE: String = "share_unavailable"

    /** The server returned no `embed_url` for the hosted leaderboard page (older server). */
    public const val HOSTED_PAGE_UNAVAILABLE: String = "hosted_page_unavailable"

    public const val REFERRER_NOT_FOUND: String = "referrer_not_found"
    public const val LEADERBOARD_NOT_FOUND: String = "leaderboard_not_found"
    public const val PERIOD_NOT_FOUND: String = "period_not_found"
    public const val INVALID_SEGMENT: String = "invalid_segment"
    public const val CODE_NOT_FOUND: String = "code_not_found"
    public const val CODE_EXPIRED: String = "code_expired"
    public const val CODE_DISABLED: String = "code_disabled"
    public const val REDEMPTION_LIMIT_REACHED: String = "redemption_limit_reached"
    public const val RATE_LIMITED: String = "rate_limited"
}
