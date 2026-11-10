package com.clikgate

/** The outcome of a [Clikgate.goal] call. */
public enum class GoalStatus(
    /** The wire value: `counted`, `waiting`, `received` or `refused`. */
    public val value: String,
) {
    /** Counted now. */
    COUNTED("counted"),

    /** Stored, not counted yet: a Payment goal waiting for its confirmation, or a goal waiting for its click. */
    WAITING("waiting"),

    /**
     * Stored, not counted: the name isn't ticked as a goal in the dashboard yet (reason `not_counted_yet`), or the
     * goal is archived (reason `goal_archived`). A success: the SDK doesn't retry it. It counts from the moment the
     * name is ticked ("Count this as a goal").
     */
    RECEIVED("received"),

    /**
     * Not counted; [GoalResult.reason] says why. Final: the SDK never retries or re-queues it. When the organisation
     * accepts only goals it has set up, a name with no goal behind it is refused with `unknown_goal` (and an archived
     * goal with `goal_archived`); debug builds log "Goal `name` isn't set up in Clikgate".
     */
    REFUSED("refused"),
}

/**
 * A goal's kind, set in the goal's settings (never in the call). A Payment goal counts only when your
 * payment provider or server confirms it, with the confirmed amount.
 */
public enum class GoalKind(
    /** The wire value: `standard` or `payment`. */
    public val value: String,
) {
    STANDARD("standard"),
    PAYMENT("payment"),
}

/**
 * What Clikgate did with a goal.
 *
 * @property status [GoalStatus.COUNTED], [GoalStatus.WAITING], [GoalStatus.RECEIVED] or [GoalStatus.REFUSED].
 * @property reason Null when counted; else a reason code such as `waiting_for_confirmation`, `not_counted_yet`,
 *   `goal_archived`, `unknown_goal`, `unattributed`, `payment_goal_needs_confirmation` or `invalid_argument`.
 * @property goalKind The goal's kind, when the server said.
 * @property valueIgnored True when a value was sent for a Payment goal and dropped (the amount comes
 *   from the confirmation).
 */
public data class GoalResult(
    val status: GoalStatus,
    val reason: String?,
    val goalKind: GoalKind?,
    val valueIgnored: Boolean,
)

/** Receives a goal's [GoalResult] on the main thread, once Clikgate has answered. */
public fun interface GoalResultListener {
    public fun onResult(result: GoalResult)
}

/** The Clikgate link behind a deep link or attribution. */
public data class ClikgateLink(
    val id: String,
    /** `standard` or `referral`. */
    val kind: String,
    val externalReference: String?,
    val campaignId: String?,
    val metadata: Map<String, Any?>,
)

/** A referral (the current installation as referee). */
public data class Referral(
    val referralId: String,
    val programId: String,
    /** `installed`, `signed_up`, `in_progress`, `holding`, `qualified`, `disqualified` or `rejected`. */
    val status: String,
    /** `link`, `code_entry`, `byo_code` or `offline_code`; null when the server didn't say. */
    val source: String?,
    val referrerId: String,
    val referrerDisplayName: String?,
    /** ISO 8601 UTC timestamp. */
    val createdAt: String?,
)

/** A deep link delivered to [Clikgate.onDeepLink]: deferred (after install) or direct. */
public data class ClikgateDeepLink(
    val url: String?,
    val path: String?,
    val data: Map<String, Any?>,
    /** True for the deferred deep link from the first launch after install. */
    val isDeferred: Boolean,
    val clickId: String?,
    /** `app_link`, `install_referrer`, `code_entry`, ...; null when unknown. */
    val matchType: String?,
    val link: ClikgateLink?,
    val referral: Referral?,
    /**
     * Set when the link is blocked here (allowed countries or a block rule): show this
     * text and don't route. `path`, `clickId` and `link` are null.
     */
    val blockMessage: String? = null,
)

/** Install attribution for this installation. */
public data class ClikgateAttribution(
    /** `pending`, `attributed` or `organic`. */
    val status: String,
    val matchType: String?,
    val confidence: Double?,
    val clickId: String?,
    /** ISO 8601 UTC timestamp of the click. */
    val clickedAt: String?,
    val isReinstall: Boolean,
    /** Clikgate install id (`ins_...`); null until `/install` succeeded. */
    val installId: String?,
    val link: ClikgateLink?,
) {
    public val isAttributed: Boolean get() = status == STATUS_ATTRIBUTED

    public companion object {
        public const val STATUS_PENDING: String = "pending"
        public const val STATUS_ATTRIBUTED: String = "attributed"
        public const val STATUS_ORGANIC: String = "organic"
    }
}

/** Whether this installation was referred, and the most recent referral. */
public data class ReferredBy(val referred: Boolean, val referral: Referral?)

/** Feature keys for [Clikgate.isFeatureEnabled] (the SDK-relevant organisation features). */
public object ClikgateFeatures {
    public const val APP_ATTRIBUTION: String = "app_attribution"
    public const val REFERRALS: String = "referrals"
    public const val LEADERBOARDS: String = "leaderboards"
    public const val IDENTITY_CHECKS: String = "identity_checks"
    public const val WHATSAPP_ATTRIBUTION: String = "whatsapp_attribution"
    public const val OFFLINE_CODES: String = "offline_codes"
    public const val SKAN_POSTBACKS: String = "skan_postbacks"
    public const val UNINSTALL_TRACKING: String = "uninstall_tracking"
    public const val PROBABILISTIC_MATCHING: String = "probabilistic_matching"
    public const val APPLE_SEARCH_ADS: String = "apple_search_ads"
}

/** Push provider of a token passed to [Clikgate.setPushToken]. */
public enum class PushProvider(public val wireName: String) {
    FCM("fcm"),
    APNS("apns"),
}

/**
 * An error reported by the SDK or the Clikgate API.
 *
 * [code] is the backend error code (`code_not_found`, `already_referred`, `window_expired`,
 * `self_referral`, `identity_required`, `not_identified`, `program_paused`, ...) or one of the SDK codes in the companion object ([FEATURE_DISABLED] when
 * the feature is switched off for the app).
 */
public class ClikgateError(
    public val code: String,
    message: String,
    /** HTTP status when the error came from the API. */
    public val status: Int? = null,
    /** The request field the error refers to, when the API reported one. */
    public val param: String? = null,
    cause: Throwable? = null,
    /** For [FEATURE_DISABLED]: the switched-off feature key (`leaderboards`, `offline_codes`, ...). */
    public val feature: String? = null,
    /**
     * Engage `codes.redeem` only: the offline touch that was recorded although the referral could not be
     * created (`self_referral`, `already_referred`, `window_expired`, ...).
     */
    public val offlineTouchId: String? = null,
) : Exception(message, cause) {
    override fun toString(): String =
        "ClikgateError(code=$code, status=$status, param=$param, " +
            (if (feature != null) "feature=$feature, " else "") +
            (if (offlineTouchId != null) "offlineTouchId=$offlineTouchId, " else "") +
            "message=$message)"

    public companion object {
        public const val NOT_CONFIGURED: String = "not_configured"
        public const val NETWORK_ERROR: String = "network_error"
        public const val OPTED_OUT: String = "opted_out"
        public const val INVALID_ARGUMENT: String = "invalid_argument"
        public const val TIMEOUT: String = "timeout"
        public const val INSTALL_PENDING: String = "install_pending"
        public const val INVALID_SDK_KEY: String = "invalid_sdk_key"
        public const val SDK_DISABLED: String = "sdk_disabled"
        public const val SERVER_ERROR: String = "server_error"

        /**
         * The feature behind the call (see [ClikgateFeatures]) is switched off for this app: either
         * the cached config says so (no network call was made) or the server answered with its
         * `feature_disabled` no-op body. [feature] names it.
         */
        public const val FEATURE_DISABLED: String = "feature_disabled"

        /**
         * Consent is required for this device and `attribution` isn't granted, so the SDK
         * makes no identifying call (referral calls, the Engage request context).
         */
        public const val CONSENT_REQUIRED: String = "consent_required"

        /** This SDK version is blocked by Clikgate's version policy for this call; update the SDK. */
        public const val SDK_VERSION_BLOCKED: String = "sdk_version_blocked"
    }
}

/** Result of an asynchronous SDK call: a value or a [ClikgateError]. */
public sealed class ClikgateResult<out T> {
    public data class Success<out T>(val value: T) : ClikgateResult<T>()
    public data class Failure(val error: ClikgateError) : ClikgateResult<Nothing>()

    public val isSuccess: Boolean get() = this is Success

    public fun getOrNull(): T? = (this as? Success)?.value
    public fun errorOrNull(): ClikgateError? = (this as? Failure)?.error
    public fun getOrThrow(): T = when (this) {
        is Success -> value
        is Failure -> throw error
    }
}

/** Callback for asynchronous calls; always invoked on the main thread. */
public fun interface ClikgateCallback<T> {
    public fun onResult(result: ClikgateResult<T>)
}

/** Receives every deep link (deferred and direct) on the main thread. */
public fun interface DeepLinkListener {
    public fun onDeepLink(deepLink: ClikgateDeepLink)
}

/**
 * A link on a shared Clikgate domain (`ciz.to`, `clk.ng`, `clkg.to`, `dev.ciz.to`) that isn't this
 * app's (`/resolve` answered `matched: false`): the SDK opened [url] in an in-app browser (Custom Tabs)
 * instead of the app. No deep link is delivered for it.
 */
public data class ClikgateBrowserHandoff(val url: String, val host: String)

/** Receives [ClikgateBrowserHandoff]s on the main thread. */
public fun interface BrowserHandoffListener {
    public fun onBrowserHandoff(handoff: ClikgateBrowserHandoff)
}

/** Receives the install attribution on the main thread. */
public fun interface AttributionListener {
    public fun onAttribution(attribution: ClikgateAttribution)
}

/**
 * Marks APIs meant for Clikgate's own packages (the Flutter / React Native wrappers and the
 * Engage add-on `com.clikgate:clikgate-engage`). They may change without notice; apps shouldn't
 * use them.
 */
@RequiresOptIn(level = RequiresOptIn.Level.ERROR, message = "Internal Clikgate wrapper API.")
@Retention(AnnotationRetention.BINARY)
@Target(AnnotationTarget.FUNCTION, AnnotationTarget.PROPERTY, AnnotationTarget.CLASS)
public annotation class ClikgateInternalApi

/**
 * Internal request context for the Engage add-on (`com.clikgate:clikgate-engage`) and the
 * wrappers: what a `/v1/sdk/...` call needs to act for this installation. Obtained from
 * [Clikgate.requestContext] once the first `/install` succeeded. A snapshot: get a fresh one per
 * call (the identity token changes with [Clikgate.identifyUser]).
 */
@ClikgateInternalApi
public class ClikgateRequestContext(
    public val installationId: String,
    public val sdkKey: String,
    /** `production` or `sandbox` ([ClikgateOptions.environment]). */
    public val environment: String,
    /** Base URL without trailing slash, e.g. `https://sdk.clikgate.com`. */
    public val apiBaseUrl: String,
    /** The identity token stored by [Clikgate.identifyUser], if any. */
    public val identityToken: String?,
    /** The user id stored by [Clikgate.identifyUser]; null when the installation isn't identified. */
    public val customerUserId: String?,
    /** Value of the `Clikgate-SDK-Version` header (`android/1.0.0`, `flutter/1.0.0`, ...). */
    public val sdkVersion: String,
    /** Value of the `Clikgate-SDK-Native-Version` header when wrapped, else null. */
    public val nativeSdkVersion: String?,
) {
    /** The contract's request headers for this context (SDK key, versions, installation id, identity token). */
    public fun headers(): Map<String, String> {
        val h = LinkedHashMap<String, String>()
        h["Clikgate-SDK-Key"] = sdkKey
        h["Clikgate-SDK-Version"] = sdkVersion
        if (nativeSdkVersion != null) h["Clikgate-SDK-Native-Version"] = nativeSdkVersion
        h["Clikgate-Installation-Id"] = installationId
        if (identityToken != null) h["Clikgate-Identity-Token"] = identityToken
        return h
    }

    override fun toString(): String =
        "ClikgateRequestContext(installationId=$installationId, environment=$environment, apiBaseUrl=$apiBaseUrl, " +
            "identified=${customerUserId != null}, sdkVersion=$sdkVersion)"
}

/**
 * Receives [Clikgate.getInstallationId]'s answer on the main thread: this installation's ID, or null when tracking is
 * off (opt-out, consent denied or not given yet where it's required, or deep-link-only mode).
 */
public fun interface InstallationIdListener {
    public fun onInstallationId(installationId: String?)
}
