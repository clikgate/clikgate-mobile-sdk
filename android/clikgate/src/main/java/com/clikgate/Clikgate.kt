package com.clikgate

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.clikgate.internal.Core
import com.clikgate.internal.CustomTabsOpener
import com.clikgate.internal.DeepLinkDispatcher
import com.clikgate.internal.Deps
import com.clikgate.internal.HandoffDispatcher
import com.clikgate.internal.Log
import com.clikgate.internal.SdkConfig
import com.clikgate.internal.WrapperInfo
import org.json.JSONObject
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

/**
 * Clikgate Android SDK (core): deep links, install attribution, goals, identifyUser, referee-side
 * referral calls, push token / uninstall tracking and feature switches. Call [configure] once from
 * `Application.onCreate`. All methods are thread-safe and non-blocking; callbacks run on the main
 * thread.
 *
 * Referral links and stats, leaderboards, promo codes and share helpers are not in the core SDK:
 * call the Clikgate API from your backend (recommended) or, in apps without a backend, use the
 * optional Engage add-on `com.clikgate:clikgate-engage`.
 */
public object Clikgate {

    /** Version of this native SDK. */
    public const val sdkVersion: String = BuildConfig.SDK_VERSION

    private const val HANDLED_EXTRA = "com.clikgate.handled"
    private const val MAX_PRE_CONFIGURE_ACTIONS = 100

    private val lock = Any()

    @Volatile
    private var core: Core? = null
    private var wrapper: WrapperInfo? = null
    private val preConfigure = ArrayList<(Core) -> Unit>()
    private val dispatcher = DeepLinkDispatcher()
    private val handoffs = HandoffDispatcher()
    private var lifecycleObserver: DefaultLifecycleObserver? = null

    /** Referee-side referral calls tied to this installation (`applyCode`, `referredBy`). */
    @JvmStatic
    public val referrals: ClikgateReferrals = ClikgateReferrals

    /**
     * Whether an organisation feature ([ClikgateFeatures]: `referrals`, `leaderboards`,
     * `offline_codes`, `identity_checks`, ...) is switched on for this app, from the cached
     * `/config` (refreshed on launch, at most hourly). Before the first config is known (or
     * before [configure]), and for features an older server doesn't list, the catalogue defaults
     * apply: `referrals`, `leaderboards`, `offline_codes`, `app_attribution` and `deep_linking` on,
     * everything else off. Unknown keys are off. A feature the server just answered `feature_disabled` for
     * reads as off until the next config fetch.
     *
     * Calls of a switched-off feature fail with [ClikgateError.FEATURE_DISABLED] without a
     * network call, so checking first is only needed to hide UI.
     */
    @JvmStatic
    public fun isFeatureEnabled(key: String): Boolean =
        core?.isFeatureEnabled(key) ?: SdkConfig.DEFAULT.isFeatureEnabled(key)

    // ---------------------------------------------------------------- setup

    /**
     * Starts the SDK. Call once, as early as possible (`Application.onCreate`). Returns
     * immediately; later calls are ignored.
     */
    @JvmStatic
    @JvmOverloads
    public fun configure(context: Context, sdkKey: String, options: ClikgateOptions = ClikgateOptions()) {
        val app = context.applicationContext ?: context
        configureInternal(app, sdkKey, options, null, registerLifecycle = true)
    }

    internal fun configureInternal(
        context: Context,
        sdkKey: String,
        options: ClikgateOptions,
        deps: Deps?,
        registerLifecycle: Boolean,
    ): Boolean {
        val created: Core
        val queued: List<(Core) -> Unit>
        synchronized(lock) {
            if (core != null) {
                Log.w("Clikgate.configure called more than once; ignoring")
                return false
            }
            Log.level = options.logLevel
            if (!sdkKey.startsWith("cg_sdk_")) Log.w("The SDK key doesn't look like a Clikgate SDK key (cg_sdk_...)")
            created = Core(sdkKey, options, deps ?: Deps.default(context, options), dispatcher, wrapper, sdkVersion, handoffs)
            core = created
            queued = ArrayList(preConfigure)
            preConfigure.clear()
        }
        // Calls made before configure() (opt-out, push token, identifyUser, intents) apply first.
        queued.forEach { it(created) }
        created.start()
        if (registerLifecycle) registerLifecycle(created)
        return true
    }

    private fun registerLifecycle(c: Core) {
        val observer = object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) = c.onForeground()
            override fun onStop(owner: LifecycleOwner) = c.onBackground()
        }
        lifecycleObserver = observer
        val register = Runnable {
            try {
                ProcessLifecycleOwner.get().lifecycle.addObserver(observer)
            } catch (t: Throwable) {
                Log.w("ProcessLifecycleOwner unavailable; opens/flushes on foreground disabled", t)
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) register.run() else Handler(Looper.getMainLooper()).post(register)
    }

    /**
     * Used by the Flutter / React Native wrappers before [configure] so request headers report
     * both versions (`Clikgate-SDK-Version: flutter/1.0.0`, `Clikgate-SDK-Native-Version: android/1.0.0`).
     */
    @ClikgateInternalApi
    @JvmStatic
    public fun setWrapper(name: String, version: String) {
        synchronized(lock) { wrapper = WrapperInfo(name, version) }
    }

    @JvmStatic
    public val isConfigured: Boolean get() = core != null

    internal fun coreOrNull(): Core? = core

    /** Runs [action] now, or right after [configure] if it hasn't been called yet. */
    private fun withCore(action: (Core) -> Unit) {
        val c = synchronized(lock) {
            core ?: run {
                if (preConfigure.size < MAX_PRE_CONFIGURE_ACTIONS) preConfigure.add(action)
                else Log.w("Clikgate used before configure(); dropping call")
                null
            }
        } ?: return
        action(c)
    }

    // ---------------------------------------------------------------- deep links

    /**
     * Hands the SDK the intent the activity was started with. Call from `onCreate` and
     * `onNewIntent`. Returns true when the intent carries a Clikgate link (App Link on a
     * Clikgate domain, or your custom scheme with `cg_click_id`); the result is delivered to
     * [onDeepLink]. Each intent is handled once.
     */
    @JvmStatic
    public fun handleIntent(activity: Activity?, intent: Intent?): Boolean {
        val data = intent?.data ?: return false
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return false
        if (activity != null) CustomTabsOpener.currentActivity = java.lang.ref.WeakReference(activity)
        val alreadyHandled = try {
            intent.getBooleanExtra(HANDLED_EXTRA, false)
        } catch (_: Exception) {
            false
        }
        val c = core
        if (c == null) {
            // configure() not called yet (e.g. a Flutter app configures from Dart): handle later.
            if (!alreadyHandled) {
                intent.putExtra(HANDLED_EXTRA, true)
                val url = data.toString()
                withCore { it.handleUrl(url) }
            }
            return false
        }
        val isClikgate = c.isClikgateUrl(data)
        if (alreadyHandled) return isClikgate
        intent.putExtra(HANDLED_EXTRA, true)
        return c.handleUrl(data.toString())
    }

    /** Handles a URL received some other way (e.g. a QR code). Same rules as [handleIntent]. */
    @JvmStatic
    public fun handleUrl(uri: Uri): Boolean {
        val c = core
        if (c == null) {
            val url = uri.toString()
            withCore { it.handleUrl(url) }
            return false
        }
        return c.handleUrl(uri.toString())
    }

    @JvmStatic
    public fun handleUrl(url: String): Boolean = handleUrl(Uri.parse(url))

    /**
     * Sets the listener for every deep link (deferred and direct), replacing any previous one;
     * null removes it. Links received while no listener is set are buffered (latest 10) and
     * delivered when one is set.
     */
    @JvmStatic
    public fun onDeepLink(listener: DeepLinkListener?) {
        dispatcher.setListener(listener)
    }

    /**
     * Sets the listener told when the SDK opened a shared-domain link of another organisation in an
     * in-app browser instead of delivering a deep link ([ClikgateBrowserHandoff],
     * [ClikgateOptions.platformDomainBrowserFallback]); null removes it. Buffered like [onDeepLink].
     */
    @JvmStatic
    public fun onBrowserHandoff(listener: BrowserHandoffListener?) {
        handoffs.setListener(listener)
    }

    // ---------------------------------------------------------------- attribution

    /**
     * Delivers the install attribution. On the first launch it waits for `/install` up to
     * `deferredDeepLinkTimeoutMs`, then resolves with status `pending`.
     */
    @JvmStatic
    public fun attribution(listener: AttributionListener) {
        val main = Handler(Looper.getMainLooper())
        withCore { c -> c.attribution { a -> main.post { listener.onAttribution(a) } } }
    }

    /** Suspending variant of [attribution]. */
    @JvmStatic
    public suspend fun awaitAttribution(): ClikgateAttribution = suspendCoroutine { cont ->
        attribution { cont.resume(it) }
    }

    // ---------------------------------------------------------------- goals / identity

    /**
     * Records a goal: an outcome your business chose, such as `account_opened`, `loan_disbursed` or
     * `purchase`, attributed to the click or install that brought this user. `goal()` is the only method for
     * what happens in your app:
     * `Clikgate.goal("account_opened", value = BigDecimal("2000000"), currency = "NGN", reference = "APP-55231", isFirst = true)`.
     * [isFirst] is sent but only your server's `is_first` decides a new customer; [label] sets the
     * person's label like [identifyUser] (needs Growth; dropped in private mode unless labels are allowed).
     *
     * For a Payment goal, pass your payment provider's reference and the provider:
     * `Clikgate.goal("purchase", reference = "T123456", provider = Provider.PAYSTACK)`. The goal's kind
     * is set in its settings, never in the call: a Payment goal counts only when your payment provider
     * or server confirms it, with the confirmed amount (a value sent from the app is ignored).
     *
     * Validated locally (key `^[a-z][a-z0-9_]*$`, 2–40 characters; [value] in normal units, ≥ 0, at most
     * 15 significant digits; [currency] ISO 4217; [reference] 1–128 characters, a UUID when null);
     * invalid goals are logged and refused. Queued, retried and consent-buffered, and idempotent by
     * `(key, reference)`. Works in private mode. Never put customer data in a goal: use your own reference
     * only. Works on every plan (basic app attribution is included). A name counts once it's ticked as a
     * goal in the dashboard ("Seen from your app and website" › "Count this as a goal").
     *
     * [onResult] gets the [GoalResult] on the main thread once Clikgate has answered: [GoalStatus.COUNTED],
     * [GoalStatus.WAITING] (for example a Payment goal waiting for its confirmation), [GoalStatus.RECEIVED]
     * (stored, not counted: the name isn't ticked yet; not retried) or [GoalStatus.REFUSED] with a reason.
     * A goal still queued when the app is closed is sent on a later launch, without a result.
     */
    @OptIn(ClikgateInternalApi::class)
    @JvmStatic
    @JvmOverloads
    public fun goal(
        key: String,
        value: java.math.BigDecimal? = null,
        currency: String? = null,
        reference: String? = null,
        provider: Provider? = null,
        isFirst: Boolean? = null,
        label: String? = null,
        onResult: GoalResultListener? = null,
    ) {
        goalInternal(key, value, currency, reference, provider?.value, isFirst, label, onResult)
    }

    private fun goalInternal(
        key: String,
        value: java.math.BigDecimal?,
        currency: String?,
        reference: String?,
        provider: String?,
        isFirst: Boolean?,
        label: String?,
        onResult: GoalResultListener?,
    ): ClikgateError? {
        val c = core
        if (c != null) return c.goal(key, value, currency, reference, provider, isFirst, label, onResult)
        // Validate now; the goal keeps the call's time (and generated reference) when enqueued after configure.
        val at = System.currentTimeMillis()
        val built = try {
            com.clikgate.internal.Goals.build(key, value, currency, reference, provider, isFirst, null, at)
        } catch (e: ClikgateError) {
            Log.e("goal(\"$key\") rejected: ${e.message}")
            if (onResult != null) Handler(Looper.getMainLooper()).post { onResult.onResult(com.clikgate.internal.Goals.refused(ClikgateError.INVALID_ARGUMENT)) }
            return e
        }
        val ref = built.getString("reference")
        withCore { it.goal(key, value, currency, ref, provider, isFirst, label, onResult, at) }
        return null
    }

    /**
     * Wrapper entry point: [goal] with the value as a decimal string (`"1500.50"`), so Flutter and
     * React Native never pass a double, and the provider as its wire string. An unparsable value or a
     * malformed provider is `invalid_argument` (returned, and refused through [onResult]).
     */
    @ClikgateInternalApi
    @JvmStatic
    public fun goalFromWrapper(
        key: String,
        value: String?,
        currency: String?,
        reference: String?,
        provider: String?,
        isFirst: Boolean?,
        onResult: GoalResultListener?,
        label: String? = null,
    ): ClikgateError? {
        fun invalid(msg: String, param: String): ClikgateError {
            Log.e("goal(\"$key\") rejected: $msg")
            if (onResult != null) Handler(Looper.getMainLooper()).post { onResult.onResult(com.clikgate.internal.Goals.refused(ClikgateError.INVALID_ARGUMENT)) }
            return ClikgateError(ClikgateError.INVALID_ARGUMENT, msg, param = param)
        }
        val decimal = if (value == null) null else com.clikgate.internal.Goals.parseValue(value)
            ?: return invalid("Goal value must be a plain decimal number", "value")
        val p = if (provider == null) null else Provider.fromString(provider)
            ?: return invalid("Provider must be a provider key like \"paystack\" (^[a-z][a-z0-9_]{1,29}\$)", "provider")
        return goalInternal(key, decimal, currency, reference, p?.value, isFirst, label, onResult)
    }

    /**
     * Tells Clikgate who this user is: an optional [label] your team sees instead of the click ID
     * (1–80 characters; "" clears it; needs Growth), your [customerId] (null clears it; leave it out
     * to keep the stored one) and an [identityToken] from your backend (required by referral programs
     * with `require_identity_token`). Calling it with nothing is a no-op. In private mode the customer
     * ID and token are dropped on the device, and the label too unless your organisation allows labels
     * in private mode. Don't put information in labels that your customers wouldn't expect you to keep.
     *
     * Identity Path A (the default): your server makes the token with the server SDK's `createIdentityToken`
     * (it reads `CLIKGATE_IDENTITY_SECRET`; never put the secret in the app) and returns it in the sign-in and
     * "current user" responses; the app passes the newest one here. Call after sign-in or sign-up and at app open
     * when already signed in; on sign-out call `identifyUser(customerId = null)`. Path B needs no token: see
     * [getInstallationId]. Guide: https://clikgate.com/docs/identify-users.
     */
    @JvmStatic
    @JvmOverloads
    public fun identifyUser(label: String? = null, customerId: String? = KEEP_CUSTOMER_ID, identityToken: String? = null) {
        val set = customerId != KEEP_CUSTOMER_ID
        withCore { it.identifyUser(label, set, if (set) customerId else null, identityToken) }
    }

    /** identifyUser()'s "customerId not passed" default (never a real customer ID). */
    private const val KEEP_CUSTOMER_ID = "\u0000"

    /**
     * This installation's ID: the random UUID the SDK created at first launch and sends to Clikgate with every
     * call (not personal data; allowed in private mode). For identity Path B: send it to your own server with the
     * sign-in request (and at every signed-in app open), and your server calls the server SDK's
     * `identifyUser({appId, installationId, customerId, label?})`. No identity secret or token is needed.
     * See https://clikgate.com/docs/identify-users.
     *
     * The listener runs on the main thread. Right after [configure] it waits for the first launch's config answer
     * (a few seconds at most; offline it answers at once), never blocking the main thread. A reinstall gets a new
     * ID. Null when tracking is off: [setTrackingEnabled] `false`, consent denied (or not given yet) where it's
     * required, or deep-link-only mode, so your server simply skips `identifyUser`.
     */
    @JvmStatic
    public fun getInstallationId(listener: InstallationIdListener) {
        withCore { c -> c.installationIdForApp { listener.onInstallationId(it) } }
    }

    /** Suspending [getInstallationId]: `val id = Clikgate.getInstallationId()`. Null when tracking is off. */
    @JvmStatic
    public suspend fun getInstallationId(): String? = suspendCoroutine { cont ->
        getInstallationId { cont.resume(it) }
    }

    /**
     * Opt-out switch. `false` clears queued goals, tells Clikgate to stop processing and erase
     * device data for this installation, and stops all other calls; `true` resumes.
     */
    @JvmStatic
    public fun setTrackingEnabled(enabled: Boolean) {
        withCore { it.setTrackingEnabled(enabled) }
    }

    // ---------------------------------------------------------------- consent

    /**
     * Sets the user's consent per purpose (B.3). A null argument leaves that purpose unchanged; all
     * purposes are [ConsentState.UNKNOWN] until set. When consent is required for this device (see
     * [getConsent]) and `attribution` is unknown, the SDK buffers goals locally (up to 7 days /
     * 1,000 goals) and sends nothing identifying; on grant it sends the buffer, on deny it drops it.
     * Consent is sent with every request. Safe to call before [configure].
     */
    @JvmStatic
    @JvmOverloads
    public fun setConsent(
        analytics: ConsentState? = null,
        attribution: ConsentState? = null,
        adUserData: ConsentState? = null,
        adPersonalization: ConsentState? = null,
    ) {
        withCore { it.setConsent(analytics, attribution, adUserData, adPersonalization) }
    }

    /**
     * The consent set with [setConsent], the region hint and whether consent is required for this
     * device (null until known). Before [configure]: all unknown.
     */
    @JvmStatic
    public fun getConsent(): ClikgateConsent = core?.getConsent()
        ?: ClikgateConsent(ConsentState.UNKNOWN, ConsentState.UNKNOWN, ConsentState.UNKNOWN, ConsentState.UNKNOWN, null, null)

    /**
     * Region hint for consent (`"EEA"`, `"UK"` or an ISO 3166-1 alpha-2 country such as `"DE"`); null
     * clears it. Clikgate otherwise uses the request's country. Invalid values are ignored (logged).
     */
    @JvmStatic
    public fun setConsentRegion(region: String?) {
        val normalized = region?.let { com.clikgate.internal.Consent.normalizeRegion(it) }
        if (region != null && normalized == null) {
            Log.e("setConsentRegion(\"$region\") ignored: use EEA, UK or an ISO 3166-1 alpha-2 country code")
            return
        }
        withCore { it.setConsentRegion(normalized) }
    }

    // ---------------------------------------------------------------- Firebase / sales

    /**
     * Forwards Clikgate attribution to Firebase Analytics when the app includes it (detected at
     * runtime; no dependency): `clikgate_attribution` once per install, the `cg_first_source` /
     * `cg_first_campaign` user properties. Also reports
     * Firebase's app instance id to Clikgate (for server-side GA4). Needs `analytics` consent and
     * the app's GA4 forwarding setting in Clikgate. Call on every launch.
     */
    @JvmStatic
    @JvmOverloads
    public fun enableFirebaseForwarding(options: FirebaseForwardingOptions = FirebaseForwardingOptions()) {
        withCore { it.enableFirebaseForwarding(options) }
    }

    /**
     * `{"cg_click_id": ..., "cg_link_id": ...}` for the click that brought this user (latest deep
     * link, else the install attribution), to put in Paystack `metadata` / Flutterwave `meta` so
     * Clikgate can match the sale. Empty when there is none or consent doesn't allow attribution.
     */
    @JvmStatic
    public fun attributionMetadata(): Map<String, String> = core?.attributionMetadata() ?: emptyMap()

    // ---------------------------------------------------------------- push / uninstall

    /**
     * Registers the push token used for uninstall checks (e.g. from
     * `FirebaseMessagingService.onNewToken` and `FirebaseMessaging.getInstance().token`).
     * Sent only when it changed since the last successful send.
     */
    @JvmStatic
    @JvmOverloads
    public fun setPushToken(token: String?, provider: PushProvider = PushProvider.FCM) {
        withCore { it.setPushToken(token, provider) }
    }

    /**
     * True for Clikgate's silent uninstall-check pushes (`data["cg"] == "uc"`, or an APNs-style
     * `cg.t == "uc"`). Call first in `onMessageReceived` and return without showing anything.
     */
    @JvmStatic
    public fun isClikgateMessage(data: Map<String, *>?): Boolean {
        val cg = data?.get("cg") ?: return false
        return when (cg) {
            is String -> cg == "uc" || (cg.startsWith("{") && try {
                JSONObject(cg).optString("t") == "uc"
            } catch (_: Exception) {
                false
            })
            is Map<*, *> -> cg["t"] == "uc"
            is Bundle -> cg.get("t") == "uc"
            is JSONObject -> cg.optString("t") == "uc"
            else -> false
        }
    }

    /** [isClikgateMessage] for an intent extras bundle. */
    @JvmStatic
    public fun isClikgateMessage(extras: Bundle?): Boolean {
        if (extras == null) return false
        @Suppress("DEPRECATION")
        val cg = extras.get("cg") ?: return false
        return isClikgateMessage(mapOf("cg" to cg))
    }

    // ---------------------------------------------------------------- Engage add-on (internal)

    /**
     * Internal (Engage add-on, wrappers): the request context for a `/v1/sdk/...` call on behalf of
     * this installation, delivered on the main thread once the first `/install` succeeded (waits up
     * to 10 s, else `install_pending`) and a pending [identifyUser] was sent. Fails with
     * `not_configured`, `opted_out`, `invalid_sdk_key` or `sdk_disabled`.
     */
    @ClikgateInternalApi
    @JvmStatic
    public fun requestContext(callback: ClikgateCallback<ClikgateRequestContext>) {
        val c = core
        if (c == null) {
            Handler(Looper.getMainLooper()).post {
                callback.onResult(ClikgateResult.Failure(ClikgateError(ClikgateError.NOT_CONFIGURED, "Call Clikgate.configure() first")))
            }
            return
        }
        c.requestContext(callback::onResult)
    }

    /** Suspending [requestContext]; throws [ClikgateError]. */
    @ClikgateInternalApi
    @JvmStatic
    public suspend fun awaitRequestContext(): ClikgateRequestContext = suspendCoroutine { cont ->
        requestContext { r ->
            when (r) {
                is ClikgateResult.Success -> cont.resume(r.value)
                is ClikgateResult.Failure -> cont.resumeWith(Result.failure(r.error))
            }
        }
    }

    /**
     * Internal (Engage add-on, wrappers): reports an error code a `/v1/sdk/...` call made with the
     * [requestContext] got. `feature_disabled` (with its [feature]) switches the feature off until
     * the next config fetch and refreshes the config; `invalid_sdk_key`, `sdk_disabled` and
     * `installation_unknown` apply the SDK's global error rules. Other codes are ignored.
     */
    @ClikgateInternalApi
    @JvmStatic
    public fun reportServerError(code: String, feature: String?) {
        core?.reportServerError(code, feature)
    }

    // ---------------------------------------------------------------- tests

    internal fun resetForTesting() {
        val c: Core?
        synchronized(lock) {
            c = core
            core = null
            wrapper = null
            preConfigure.clear()
        }
        c?.shutdown()
        dispatcher.reset()
        handoffs.reset()
    }
}
