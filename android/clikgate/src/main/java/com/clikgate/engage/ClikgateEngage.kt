package com.clikgate.engage

import com.clikgate.ClikgateCallback
import com.clikgate.ClikgateError
import com.clikgate.ClikgateResult
import com.clikgate.engage.EngageClient.Companion.enc
import com.clikgate.engage.EngageClient.Companion.query
import org.json.JSONObject
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine

/**
 * Clikgate Engage features (`com.clikgate.engage`, part of `com.clikgate:clikgate-android` since 2.1.0): referral links and stats,
 * leaderboards, promo / offline code redemption and share helpers for apps **without their own
 * backend**. Apps with a backend should call the Clikgate control-plane API from their server
 * instead and render their own screens (recommended path).
 *
 * Engage keeps no attribution state: every call uses the core SDK's request context
 * ([com.clikgate.Clikgate.configure] must have been called), so it needs a completed first
 * `/install`. Rules:
 * - A call of a switched-off feature ([com.clikgate.Clikgate.isFeatureEnabled]) fails with
 *   `feature_disabled` without a network call.
 * - Calls acting for the user (link, stats, my rank, around me, opt-out, hosted page) fail with
 *   [EngageErrors.NOT_IDENTIFIED] until [com.clikgate.Clikgate.identifyUser] was called; programs with
 *   `require_identity_token` answer `identity_required` until a valid token was given.
 * - Reads are cached in memory for 60 s (nothing is written to disk); writes clear the cache.
 * - At most one retry, for network errors only. Errors are [ClikgateError]s.
 * - No UI components (besides the system share sheet / WhatsApp intents of [share]).
 *
 * Callbacks run on the main thread; the `suspend` variants throw [ClikgateError].
 */
public object ClikgateEngage {
    /** Version of the Engage features (the SDK version). */
    public const val version: String = com.clikgate.BuildConfig.SDK_VERSION

    internal val client = EngageClient()

    /** Referrer side: the user's referral link and stats (feature `referrals`). */
    public val referrals: EngageReferrals = EngageReferrals

    /** System share sheet and WhatsApp share (no network). */
    public val share: EngageShare = EngageShare

    /** Leaderboards published to the SDK (feature `leaderboards`). */
    public val leaderboards: EngageLeaderboards = EngageLeaderboards

    /** Promo / offline code redemption (feature `offline_codes`). */
    public val codes: EngageCodes = EngageCodes

    /** Drops the in-memory read cache (e.g. after the user pulled to refresh). */
    public fun clearCache() {
        client.clearCache()
    }

}

/** Resumes a coroutine with a callback result (one class for every suspend variant). */
internal class Resume<T>(private val cont: Continuation<T>) : ClikgateCallback<T> {
    override fun onResult(result: ClikgateResult<T>) {
        when (result) {
            is ClikgateResult.Success -> cont.resume(result.value)
            is ClikgateResult.Failure -> cont.resumeWithException(result.error)
        }
    }
}

/** Referrer-side referral calls (`ClikgateEngage.referrals`, feature `referrals`). */
public object EngageReferrals {
    private const val FEATURE = "referrals"
    private val client get() = ClikgateEngage.client

    /**
     * Gets or creates the current user's referral link and code in [programId] (idempotent per
     * program and user). Needs [com.clikgate.Clikgate.identifyUser]. Errors include
     * `client_link_creation_disabled`, `referral_link_limit`, `identity_required`, `program_not_found`.
     */
    public fun createLink(programId: String, displayName: String? = null, callback: ClikgateCallback<ReferralLink>) {
        if (programId.isBlank()) return client.invalid(callback, "programId is required", "program_id")
        val body = JSONObject().put("program_id", programId)
        if (displayName != null) body.put("display_name", displayName)
        client.call(FEATURE, "POST", "/v1/sdk/referrals/link", body, userCall = true, cacheable = false, write = true,
            kind = EngageJson.LINK, callback = callback)
    }

    /** Suspending [createLink]. */
    public suspend fun createLink(programId: String, displayName: String? = null): ReferralLink =
        suspendCoroutine { createLink(programId, displayName, Resume(it)) }

    /** The current user's code, link and stats in [programId]; `referrer_not_found` if they have no link yet. */
    public fun myStats(programId: String, callback: ClikgateCallback<ReferralStats>) {
        if (programId.isBlank()) return client.invalid(callback, "programId is required", "program_id")
        client.call(FEATURE, "GET", "/v1/sdk/referrals/me" + query("program_id" to programId), null,
            userCall = true, cacheable = true, write = false, kind = EngageJson.STATS, callback = callback)
    }

    /** Suspending [myStats]. */
    public suspend fun myStats(programId: String): ReferralStats = suspendCoroutine { myStats(programId, Resume(it)) }
}

/**
 * Leaderboards (`ClikgateEngage.leaderboards`, feature `leaderboards`) for boards published to the
 * SDK (`visibility = sdk`). Build your own UI. Errors: `leaderboard_not_found`,
 * `referrer_not_found`, `period_not_found`, `invalid_segment`, `not_identified`,
 * `identity_required`, `identity_invalid`, ...
 */
public object EngageLeaderboards {
    private const val FEATURE = "leaderboards"
    private val client get() = ClikgateEngage.client

    private fun <T> check(leaderboardId: String, period: String, callback: ClikgateCallback<T>): Boolean {
        if (leaderboardId.isBlank() || leaderboardId.contains('/')) {
            client.invalid(callback, "leaderboardId is required", "leaderboard_id")
            return false
        }
        if (period.isBlank()) {
            client.invalid(callback, "period is required", "period")
            return false
        }
        return true
    }

    private fun path(leaderboardId: String, suffix: String) = "/v1/sdk/leaderboards/" + enc(leaderboardId) + suffix

    /**
     * Top entries of a board. [period] is [LeaderboardPeriod.CURRENT] (default),
     * [LeaderboardPeriod.PREVIOUS] or a period key (`2026-W43`); [limit] is clamped to 1..100.
     * Doesn't need an identified user.
     */
    public fun top(
        leaderboardId: String,
        period: String = LeaderboardPeriod.CURRENT,
        segment: String? = null,
        limit: Int = 50,
        callback: ClikgateCallback<LeaderboardPage>,
    ) {
        if (!check(leaderboardId, period, callback)) return
        val p = path(leaderboardId, "") + query("period" to period, "segment" to segment, "limit" to limit.coerceIn(1, 100).toString())
        client.call(FEATURE, "GET", p, null, userCall = false, cacheable = true, write = false,
            kind = EngageJson.PAGE, callback = callback)
    }

    /** Suspending [top]. */
    public suspend fun top(
        leaderboardId: String,
        period: String = LeaderboardPeriod.CURRENT,
        segment: String? = null,
        limit: Int = 50,
    ): LeaderboardPage = suspendCoroutine { top(leaderboardId, period, segment, limit, Resume(it)) }

    /**
     * The current user's rank, score, pending count, gap to the next rank and period end
     * ([MyRank.rank] is null while unranked). `referrer_not_found` when the user never had a
     * referral link in the board's program.
     */
    public fun me(
        leaderboardId: String,
        period: String = LeaderboardPeriod.CURRENT,
        segment: String? = null,
        callback: ClikgateCallback<MyRank>,
    ) {
        if (!check(leaderboardId, period, callback)) return
        val p = path(leaderboardId, "/me") + query("period" to period, "segment" to segment)
        client.call(FEATURE, "GET", p, null, userCall = true, cacheable = true, write = false,
            kind = EngageJson.RANK, callback = callback)
    }

    /** Suspending [me]. */
    public suspend fun me(
        leaderboardId: String,
        period: String = LeaderboardPeriod.CURRENT,
        segment: String? = null,
    ): MyRank = suspendCoroutine { me(leaderboardId, period, segment, Resume(it)) }

    /**
     * Up to [radius] entries above and below the current user (clamped to 1..25); the user's own
     * entry has `isMe = true`. Empty entries when the user isn't ranked; `name`, `metric` and
     * `segment` of the page are null.
     */
    public fun aroundMe(
        leaderboardId: String,
        radius: Int = 5,
        period: String = LeaderboardPeriod.CURRENT,
        segment: String? = null,
        callback: ClikgateCallback<LeaderboardPage>,
    ) {
        if (!check(leaderboardId, period, callback)) return
        val p = path(leaderboardId, "/around-me") +
            query("radius" to radius.coerceIn(1, 25).toString(), "period" to period, "segment" to segment)
        client.call(FEATURE, "GET", p, null, userCall = true, cacheable = true, write = false,
            kind = EngageJson.PAGE, callback = callback)
    }

    /** Suspending [aroundMe]. */
    public suspend fun aroundMe(
        leaderboardId: String,
        radius: Int = 5,
        period: String = LeaderboardPeriod.CURRENT,
        segment: String? = null,
    ): LeaderboardPage = suspendCoroutine { aroundMe(leaderboardId, radius, period, segment, Resume(it)) }

    /** Hides (`optOut = true`) or shows the current user on every board of [programId]. [callback] may be null. */
    public fun setOptOut(programId: String, optOut: Boolean, callback: ClikgateCallback<Unit>?) {
        val cb = callback ?: ClikgateCallback { }
        if (programId.isBlank()) return client.invalid(cb, "programId is required", "program_id")
        val body = JSONObject().put("program_id", programId).put("opt_out", optOut)
        client.call(FEATURE, "POST", "/v1/sdk/leaderboards/opt-out", body, userCall = true, cacheable = false, write = true,
            kind = EngageJson.UNIT, callback = cb)
    }

    /** Suspending [setOptOut]. */
    public suspend fun setOptOut(programId: String, optOut: Boolean): Unit =
        suspendCoroutine { setOptOut(programId, optOut, Resume(it)) }

    /**
     * A signed, short-lived URL of the hosted leaderboard page (highlighting the current user) to
     * show in a web view. Never cached. [EngageErrors.HOSTED_PAGE_UNAVAILABLE] when the server
     * returns no `embed_url`.
     */
    public fun hostedPageUrl(leaderboardId: String, period: String = LeaderboardPeriod.CURRENT, callback: ClikgateCallback<String>) {
        if (!check(leaderboardId, period, callback)) return
        val p = path(leaderboardId, "/me") + query("period" to period, "embed" to "1")
        client.call(FEATURE, "GET", p, null, userCall = true, cacheable = false, write = false,
            kind = EngageJson.EMBED_URL, callback = callback)
    }

    /** Suspending [hostedPageUrl]. */
    public suspend fun hostedPageUrl(leaderboardId: String, period: String = LeaderboardPeriod.CURRENT): String =
        suspendCoroutine { hostedPageUrl(leaderboardId, period, Resume(it)) }
}

/**
 * Promo / offline code redemption (`ClikgateEngage.codes`, feature `offline_codes`): a code from a
 * poster, flyer, USSD menu or agent typed into the app. Errors: `code_not_found`, `code_expired`,
 * `code_disabled`, `redemption_limit_reached`, `rate_limited` (5 per hour per installation), and
 * for referral codes the referral errors of `applyCode` — the touch is still recorded then and
 * [ClikgateError.offlineTouchId] carries its id.
 */
public object EngageCodes {
    private const val MIN_LENGTH = 3
    private const val MAX_LENGTH = 30

    /** Redeems [code] (trimmed, 3–30 characters; the server ignores case, spaces and dashes). */
    public fun redeem(code: String, callback: ClikgateCallback<Redemption>) {
        val client = ClikgateEngage.client
        val trimmed = code.trim()
        if (trimmed.length !in MIN_LENGTH..MAX_LENGTH) {
            return client.invalid(callback, "code must be $MIN_LENGTH-$MAX_LENGTH characters", "code")
        }
        client.call("offline_codes", "POST", "/v1/sdk/codes/redeem", JSONObject().put("code", trimmed),
            userCall = false, cacheable = false, write = true, kind = EngageJson.REDEMPTION, callback = callback)
    }

    /** Suspending [redeem]. */
    public suspend fun redeem(code: String): Redemption = suspendCoroutine { redeem(code, Resume(it)) }
}
