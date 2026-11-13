package com.clikgate.engage

import com.clikgate.ClikgateError
import com.clikgate.Referral
import org.json.JSONArray
import org.json.JSONObject

/** API (snake_case) -> Engage models. Unknown fields are ignored. */
internal object EngageJson {
    const val UNIT = 0
    const val LINK = 1
    const val STATS = 2
    const val PAGE = 3
    const val RANK = 4
    const val REDEMPTION = 5
    const val EMBED_URL = 6

    /** One dispatcher instead of a function reference (= a class) per call site. */
    fun parse(kind: Int, o: JSONObject): Any? = when (kind) {
        LINK -> referralLink(o)
        STATS -> referralStats(o)
        PAGE -> leaderboardPage(o)
        RANK -> myRank(o)
        REDEMPTION -> redemption(o)
        EMBED_URL -> myRank(o).embedUrl?.takeIf { it.isNotEmpty() }
            ?: throw ClikgateError(EngageErrors.HOSTED_PAGE_UNAVAILABLE, "The server returned no hosted page URL (embed_url)")
        else -> Unit
    }

    fun JSONObject.str(key: String): String? = if (!has(key) || isNull(key)) null else opt(key)?.toString()
    private fun JSONObject.obj(key: String): JSONObject? = if (isNull(key)) null else optJSONObject(key)
    private fun JSONObject.int(key: String): Int = if (isNull(key)) 0 else optInt(key, 0)
    private fun JSONObject.intOrNull(key: String): Int? = if (isNull(key)) null else (opt(key) as? Number)?.toInt()
    private fun JSONObject.bool(key: String): Boolean = if (isNull(key)) false else optBoolean(key, false)

    /** True for the `200 {"accepted": false, "reason": "feature_disabled"}` no-op body. */
    fun isFeatureDisabled(o: JSONObject): Boolean =
        o.str("reason") == "feature_disabled" && o.has("accepted") && !o.isNull("accepted") && !o.optBoolean("accepted", true)

    fun referral(o: JSONObject?): Referral? {
        if (o == null) return null
        return Referral(
            referralId = o.str("referral_id") ?: return null,
            programId = o.str("program_id") ?: "",
            status = o.str("status") ?: "installed",
            source = o.str("source"),
            referrerId = o.str("referrer_id") ?: "",
            referrerDisplayName = o.str("referrer_display_name"),
            createdAt = o.str("created_at"),
        )
    }

    fun referralLink(o: JSONObject) = ReferralLink(
        referrerId = o.str("referrer_id") ?: "",
        programId = o.str("program_id") ?: "",
        code = o.str("code") ?: "",
        url = o.str("url") ?: "",
        shortUrl = o.str("short_url") ?: o.str("url") ?: "",
    )

    fun referralStats(o: JSONObject): ReferralStats {
        val s = o.optJSONObject("stats") ?: JSONObject()
        return ReferralStats(
            referrerId = o.str("referrer_id") ?: "",
            programId = o.str("program_id") ?: "",
            code = o.str("code") ?: "",
            url = o.str("url") ?: "",
            shortUrl = o.str("short_url") ?: o.str("url") ?: "",
            status = o.str("status") ?: "active",
            clicks = s.int("clicks"),
            installs = s.int("installs"),
            signups = s.int("signups"),
            inProgress = s.int("in_progress"),
            qualified = s.int("qualified"),
            disqualified = s.int("disqualified"),
            rejected = s.int("rejected"),
        )
    }

    private fun period(o: JSONObject?) = LeaderboardPeriod(
        key = o?.str("key") ?: "",
        status = o?.str("status") ?: "open",
        startsAt = o?.str("starts_at"),
        endsAt = o?.str("ends_at"),
    )

    private fun entry(o: JSONObject) = LeaderboardEntry(
        rank = o.int("rank"),
        referrerId = o.str("referrer_id") ?: "",
        display = o.str("display") ?: "",
        score = o.int("score"),
        pending = o.intOrNull("pending"),
        isMe = o.bool("is_me"),
    )

    /** `GET /leaderboards/{id}` and `/around-me` (the latter has no name / metric / segment). */
    fun leaderboardPage(o: JSONObject): LeaderboardPage {
        val entries = o.optJSONArray("entries") ?: JSONArray()
        return LeaderboardPage(
            leaderboardId = o.str("leaderboard_id") ?: throw IllegalStateException("missing leaderboard_id"),
            name = o.str("name"),
            metric = o.str("metric"),
            segment = o.str("segment"),
            period = period(o.obj("period")),
            entries = (0 until entries.length()).mapNotNull { entries.optJSONObject(it)?.let(::entry) },
        )
    }

    fun myRank(o: JSONObject) = MyRank(
        leaderboardId = o.str("leaderboard_id") ?: throw IllegalStateException("missing leaderboard_id"),
        period = period(o.obj("period")),
        referrerId = o.str("referrer_id") ?: "",
        rank = o.intOrNull("rank"),
        score = o.int("score"),
        pending = o.intOrNull("pending"),
        gapToNext = o.intOrNull("gap_to_next"),
        bestRank = o.intOrNull("best_rank"),
        periodEndsAt = o.str("period_ends_at"),
        optedOut = o.bool("opted_out"),
        embedUrl = o.str("embed_url"),
    )

    fun redemption(o: JSONObject): Redemption {
        val c = o.obj("code") ?: JSONObject()
        return Redemption(
            offlineTouchId = o.str("offline_touch_id") ?: throw IllegalStateException("missing offline_touch_id"),
            code = RedeemedCode(
                code = c.str("code") ?: "",
                kind = c.str("kind") ?: "link",
                linkId = c.str("link_id"),
                campaignId = c.str("campaign_id"),
                referrerId = c.str("referrer_id"),
                programId = c.str("program_id"),
            ),
            referral = referral(o.obj("referral")),
        )
    }
}
