package com.clikgate

import com.clikgate.ApiCalls.await
import com.clikgate.ApiCalls.call
import com.clikgate.ApiCalls.invalid
import com.clikgate.internal.Json
import org.json.JSONObject

/**
 * Referee-side referral calls tied to this installation (`Clikgate.referrals`): apply a friend's
 * code, and ask whether this install was referred. Calls wait for the first-launch install (up to
 * 10 s, else `install_pending`) and send the identity token from [Clikgate.identifyUser]. Backend
 * errors (`code_not_found`, `already_referred`, `window_expired`, `self_referral`, ...) are
 * reported as [ClikgateError] and never retried automatically.
 *
 * Referrer-side features (creating the user's link, stats, sharing, leaderboards, promo codes) are
 * not in the core SDK: call the Clikgate API from your backend (recommended), or use the optional
 * Engage add-on `com.clikgate:clikgate-engage` in apps without a backend.
 *
 * When the `referrals` feature is switched off for the app, every call fails with
 * [ClikgateError.FEATURE_DISABLED] without a network call (or after the server's
 * `feature_disabled` no-op answer, if the cached config was out of date).
 */
public object ClikgateReferrals {

    /** Applies a friend's referral code for the current installation (manual code entry). */
    @JvmStatic
    public fun applyCode(programId: String, code: String, callback: ClikgateCallback<Referral>) {
        if (programId.isBlank()) return invalid(callback, "programId is required", "program_id")
        val trimmed = code.trim()
        if (trimmed.isEmpty()) return invalid(callback, "code is required", "code")
        val body = JSONObject().put("program_id", programId).put("code", trimmed)
        call(callback) {
            it.referralCall("POST", "/v1/sdk/referrals/apply-code", body, { o ->
                Json.referral(o) ?: throw IllegalStateException("missing referral")
            }, callback::onResult)
        }
    }

    /** Suspending [applyCode]. */
    public suspend fun awaitApplyCode(programId: String, code: String): Referral =
        await { applyCode(programId, code, it) }

    /** Whether this installation was referred (most recent referral across programs). */
    @JvmStatic
    public fun referredBy(callback: ClikgateCallback<ReferredBy>) {
        call(callback) { it.referralCall("GET", "/v1/sdk/referrals/referred-by", null, Json::referredBy, callback::onResult) }
    }

    /** Suspending [referredBy]. */
    public suspend fun awaitReferredBy(): ReferredBy = await { referredBy(it) }
}
