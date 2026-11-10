package com.clikgate.internal

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.clikgate.ClikgateAttribution
import com.clikgate.ClikgateBrowserHandoff
import com.clikgate.ClikgateDeepLink
import com.clikgate.ClikgateError
import com.clikgate.ClikgateFeatures
import com.clikgate.ClikgateOptions
import com.clikgate.ClikgateInternalApi
import com.clikgate.ClikgateConsent
import com.clikgate.ClikgateRequestContext
import com.clikgate.ClikgateResult
import com.clikgate.ConsentState
import com.clikgate.FirebaseForwardingOptions
import com.clikgate.GoalKind
import com.clikgate.GoalResult
import com.clikgate.GoalResultListener
import com.clikgate.GoalStatus
import com.clikgate.PushProvider
import com.clikgate.internal.Json.str
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.ThreadFactory
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Replaceable collaborators (tests swap these). */
internal class Deps(
    val storage: Storage,
    val queue: EventQueue,
    val device: DeviceInfo,
    val referrerSource: InstallReferrerSource,
    val attestation: AttestationProvider?,
    val background: BackgroundScheduler,
    val clock: () -> Long = System::currentTimeMillis,
    val backoff: Backoff = Backoff(),
    val referrerWaitsMs: List<Long> = listOf(1_000, 2_000, 4_000),
    val installWaitForReferralMs: Long = 10_000,
    val attestationTimeoutMs: Long = 10_000,
    /** Firebase Analytics (reflection; null in tests that don't need it). */
    val firebase: FirebaseAnalyticsBridge? = null,
    val appInstanceIdWaitMs: Long = 2_000,
    /** In-app browser for unmatched shared-domain links (null in tests that don't need it). */
    val browser: BrowserOpener? = null,
) {
    companion object {
        @Suppress("UNUSED_PARAMETER")
        fun default(context: Context, options: ClikgateOptions) = Deps(
            storage = Storage(context),
            queue = EventQueue(context),
            device = DeviceInfo(context),
            referrerSource = PlayInstallReferrerSource(context),
            attestation = PlayIntegrityProvider(context),
            background = WorkManagerScheduler(context),
            firebase = ReflectionFirebaseBridge(context),
            browser = CustomTabsOpener(context),
        )
    }
}

internal class WrapperInfo(val name: String, val version: String)

/**
 * The SDK engine. All mutable state is confined to the single [serial] thread; network I/O runs
 * on [network] and continues on [serial]. [pump] looks at the persisted + in-memory state and
 * starts whatever work is due, so every trigger (launch, foreground, goal, identify, ...) just
 * updates state and calls [pump].
 */
internal class Core(
    private val sdkKey: String,
    private val options: ClikgateOptions,
    private val deps: Deps,
    private val dispatcher: DeepLinkDispatcher,
    private val wrapper: WrapperInfo?,
    private val nativeVersion: String,
    private val handoffs: HandoffDispatcher = HandoffDispatcher(),
) {
    private val storage get() = deps.storage
    private val queue get() = deps.queue
    private val main = Handler(Looper.getMainLooper())

    val serial: ScheduledExecutorService = ScheduledThreadPoolExecutor(1, namedThreads("clikgate")).apply {
        removeOnCancelPolicy = true
    }
    private val network: ExecutorService = Executors.newFixedThreadPool(3, namedThreads("clikgate-net"))

    private val installationId: String = storage.installationId()
    private val http = HttpClient(options.apiBaseUrl, ::headers)

    /** Developer-configured link domains, normalised; they always count. */
    private val optionDomains: Set<String> =
        options.linkDomains.map(SdkConfig::normalizeDomain).filterTo(HashSet()) { it.isNotEmpty() }

    /** Cached config domains ∪ option domains, readable from any thread. */
    @Volatile
    var linkDomains: Set<String> = optionDomains
        private set

    /** Server domains already warned about this launch (serial thread). */
    private val warnedDomains = HashSet<String>()

    /** Features of the cached / fetched config, readable from any thread (`isFeatureEnabled`). */
    @Volatile
    private var featureConfig: SdkConfig = SdkConfig.DEFAULT

    /**
     * Features a server answered `feature_disabled` for since the last config fetch: they fail fast
     * until a fresh config says otherwise.
     */
    private val disabledByServer: MutableSet<String> = java.util.Collections.newSetFromMap(java.util.concurrent.ConcurrentHashMap())

    // ---- serial-thread state ----
    private var config = SdkConfig.DEFAULT
    private var configReady = false
    private var configInFlight = false
    private var invalidKey = false
    private var disabledUntil = 0L
    private var disabledWakeup: ScheduledFuture<*>? = null

    private val installDoneAtLaunch = storage.installDone
    private var installInFlight = false
    /** True once the `/install` body was built (a launch URL can't join it any more). */
    private var installRequestBuilt = false
    private var installStopped = false
    private var installPolls = 0
    private var pollingActive = false
    private var referrerAttempted = false
    private var deferredDelivered = false
    private var launchUrl: String? = null
    private val pendingUrls = ArrayList<String>()
    private val candidateUrls = ArrayList<String>()

    private var foreground = false
    private var seenFirstForeground = false
    private var openPending: Boolean? = null
    private var openInFlight = false
    private var flushTimer: ScheduledFuture<*>? = null

    private var pushInFlight = false
    private var pushFailedHash: String? = null
    private var identifyInFlight = false
    private var identifySeq = 0
    private var identifyFailedSeq = -1
    private var optOutInFlight = false
    private var attestInFlight = false
    private var attestTried = false

    private var flushRequested = true
    private var flushInFlight = false
    private val flushWaiters = ArrayList<(Boolean) -> Unit>()

    // ---- consent, version policy, Firebase ----
    /** Consent purposes + region hint, readable from any thread (`getConsent`, `attributionMetadata`). */
    @Volatile
    private var consentValues: ConsentValues = ConsentValues.parse(storage.consentJson)
    @Volatile
    private var firebaseOptions: FirebaseForwardingOptions? = null
    private var consentInFlight = false
    private var pingInFlight = false
    /** Clikgate URLs received while buffering for consent: resolved silently after grant. */
    private val consentBufferedUrls = ArrayList<String>()
    /** The launch URL was already delivered locally (buffering / blocked): don't deliver it twice. */
    private var launchUrlDeliveredLocally = false
    /** Google click ids of the last handled URL, for the next `/open`. */
    private var pendingOpenClickIds: JSONObject? = null
    private var appInstanceId: String? = null
    private var appInstanceIdFetched = false
    private var appInstanceIdFetching = false
    private var versionWarned = false

    // ---- goals ----
    private var privateModeWarned = false
    private var labelsWarned = false
    private var goalsUnsupportedWarned = false

    /** Listeners of queued goals by dedupe key; in memory only (a relaunch sends the goal, without a listener). */
    private val goalListeners = java.util.concurrent.ConcurrentHashMap<String, MutableList<GoalResultListener>>()

    /** Test keys (`cg_sdk_test_...`) log what happened to Payment goals and report handled deep links. */
    private val testMode = sdkKey.startsWith("cg_sdk_test_")

    private val attributionWaiters = ArrayList<Waiter<ClikgateAttribution>>()
    private val installWaiters = ArrayList<Waiter<Boolean>>()
    private val identifyWaiters = ArrayList<() -> Unit>()
    private val installationIdWaiters = ArrayList<Waiter<Unit>>()

    private class Waiter<T>(val callback: (T) -> Unit) {
        var timeout: ScheduledFuture<*>? = null
        var done = false
        fun complete(v: T) {
            if (done) return
            done = true
            timeout?.cancel(false)
            callback(v)
        }
    }

    init {
        storage.configJson?.let { cached ->
            try {
                val parsed = SdkConfig.parse(JSONObject(cached))
                linkDomains = linkDomains + parsed.linkDomains
                featureConfig = parsed
            } catch (_: Exception) {
            }
        }
    }

    fun start() = serial.execute {
        Log.i("Clikgate ${nativeVersion} started (installation ${installationId.take(8)}…)")
        pump()
    }

    fun shutdown() {
        serial.shutdownNow()
        network.shutdownNow()
    }

    // ------------------------------------------------------------------ headers / transport

    private fun headers(): Map<String, String> {
        val h = LinkedHashMap<String, String>()
        h["Clikgate-SDK-Key"] = sdkKey
        if (wrapper != null) {
            h["Clikgate-SDK-Version"] = "${wrapper.name}/${wrapper.version}"
            h["Clikgate-SDK-Native-Version"] = "android/$nativeVersion"
        } else {
            h["Clikgate-SDK-Version"] = "android/$nativeVersion"
        }
        h["Clikgate-Installation-Id"] = installationId
        return h
    }

    /**
     * Sends [req], retrying network errors / 408 / 429 / 5xx with backoff up to [maxAttempts],
     * and applies the global error rules (invalid key, kill switch, unknown installation).
     * [cb] runs on the serial thread.
     */
    private fun send(
        req: ApiRequest,
        maxAttempts: Int,
        attempt: Int = 0,
        /** Rewrites the request before a retry (e.g. drop a single-use attestation). */
        forRetry: (ApiRequest) -> ApiRequest = { it },
        /** Interactive calls don't wait longer than this for a retry (e.g. a long `Retry-After`). */
        maxRetryDelayMs: Long = Long.MAX_VALUE,
        cb: (ApiResult) -> Unit,
    ) {
        if (invalidKey) {
            cb(ApiResult.Failure(ClikgateError(ClikgateError.INVALID_SDK_KEY, "Invalid SDK key", 401), false))
            return
        }
        if (deps.clock() < disabledUntil) {
            cb(ApiResult.Failure(ClikgateError(ClikgateError.SDK_DISABLED, "SDK disabled", 403), false))
            return
        }
        network.execute {
            val r = http.execute(req)
            runSerial {
                if (r is ApiResult.Failure) {
                    applyGlobalError(r.error)
                    val delay = r.retryAfterMs ?: deps.backoff.delayMs(attempt)
                    if (r.retryable && attempt + 1 < maxAttempts && delay <= maxRetryDelayMs && !invalidKey && !serial.isShutdown) {
                        Log.d("${req.path.substringBefore('?')} failed (${r.error.code}); retry in ${delay} ms")
                        val next = forRetry(req)
                        serial.schedule({ send(next, maxAttempts, attempt + 1, forRetry, maxRetryDelayMs, cb) }, delay, TimeUnit.MILLISECONDS)
                        return@runSerial
                    }
                }
                cb(r)
            }
        }
    }

    private fun applyGlobalError(e: ClikgateError) {
        when (e.code) {
            ClikgateError.INVALID_SDK_KEY -> if (!invalidKey) {
                invalidKey = true
                Log.e("Clikgate rejected the SDK key (invalid_sdk_key). No calls until the next app launch.")
            }
            ClikgateError.SDK_DISABLED -> {
                disabledUntil = deps.clock() + TimeUnit.HOURS.toMillis(1)
                Log.w("Clikgate SDK access is disabled for this app; backing off for 1 h")
                disabledWakeup?.cancel(false)
                disabledWakeup = serial.schedule({ pump() }, 1, TimeUnit.HOURS)
            }
            "installation_unknown" -> if (storage.installDone) {
                Log.w("Server doesn't know this installation; re-running the install flow")
                storage.installDone = false
                storage.installId = null
                serial.execute { pump() }
            }
        }
    }

    private inline fun runSerial(crossinline block: () -> Unit) {
        try {
            serial.execute { block() }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
        }
    }

    // ------------------------------------------------------------------ the pump

    private fun pump() {
        if (configReady && installationIdWaiters.isNotEmpty()) {
            val ws = ArrayList(installationIdWaiters)
            installationIdWaiters.clear()
            ws.forEach { it.complete(Unit) }
        }
        if (invalidKey || serial.isShutdown) return
        if (deps.clock() < disabledUntil) return
        val tracking = storage.trackingEnabled

        if (!storage.installDone) {
            if (installInFlight || installStopped) return
            if (!tracking) {
                sendInstall(optedOutInstallBody(), optedOut = true)
                return
            }
            if (!configReady) return loadConfig()
            when (gate()) {
                Gate.PENDING -> return bufferForConsent()
                Gate.DENIED -> {
                    dropConsentBuffer()
                    maybeSendInstallPing()
                    return
                }
                Gate.ALLOWED -> storage.consentPendingSince = 0
            }
            if (!allows("install")) return
            prepareInstall()
            return
        }

        storage.pendingOptOut?.let { value ->
            if (!optOutInFlight) sendOptOut(value)
            return
        }
        if (!tracking) return
        if (!configReady) return loadConfig()

        val gate = gate()
        if (gate == Gate.PENDING) return bufferForConsent()
        if (storage.consentSendPending && !consentInFlight && allows("consent")) sendConsent()
        if (gate == Gate.DENIED) return dropConsentBuffer()
        storage.consentPendingSince = 0

        if (consentBufferedUrls.isNotEmpty()) {
            val urls = ArrayList(consentBufferedUrls)
            consentBufferedUrls.clear()
            if (allows("resolve")) urls.forEach { sendResolve(it, deliver = false) }
        }
        if (pendingUrls.isNotEmpty()) {
            val urls = ArrayList(pendingUrls)
            pendingUrls.clear()
            urls.forEach { if (allows("resolve")) sendResolve(it) else dispatcher.dispatch(localDeepLink(it)) }
        }
        if (storage.identifyPending && config.privateMode) discardIdentify()
        if (storage.identifyPending && !identifyInFlight && identifyFailedSeq != identifySeq && allows("identify")) sendIdentify()
        if (allows("push_token")) maybeSendPushToken()
        openPending?.let { cold ->
            if (!openInFlight && allows("open")) {
                // With Firebase forwarding, the first /open of a process waits (≤ 2 s) for the app instance id.
                if (!appInstanceIdFetched && appInstanceIdWanted()) maybeFetchAppInstanceId { pump() }
                else if (!appInstanceIdFetching) sendOpen(cold)
            }
        }
        if (allows("attest")) maybeReattest()
        maybeFetchAppInstanceId()
        maybeLogFirebaseAttribution()
        if (flushRequested && !flushInFlight) flush()
    }

    // ------------------------------------------------------------------ consent, version policy

    /** Whether consent is required for this device. */
    private fun consentRequired(): Boolean = Consent.required(featureConfig.consent, consentValues.region) ?: false

    private fun gate(): Gate = Consent.gate(consentValues, consentRequired())

    private fun purposeAllowed(state: ConsentState): Boolean = Consent.allowed(state, consentRequired())

    /** Identity checks: analytics consent, or the organisation's "fraud prevention" basis. */
    private fun identityChecksAllowed(): Boolean =
        purposeAllowed(consentValues.analytics) || featureConfig.consent?.identityChecksBasis == "fraud_prevention"

    private val blocked: Boolean get() = config.versionPolicy.blocked

    /** Version policy: a blocked SDK only makes the calls the server allows. */
    private fun allows(call: String): Boolean = config.versionPolicy.allows(call)

    private fun ownVersion(): String = wrapper?.version ?: nativeVersion

    private fun checkVersionPolicy() {
        if (versionWarned) return
        val p = config.versionPolicy
        when (p.effectiveStatus(ownVersion())) {
            "deprecated" -> {
                versionWarned = true
                Log.w("Clikgate SDK ${ownVersion()} is deprecated" + (p.latest?.let { "; update to $it" } ?: "") + ".")
            }
            "blocked" -> {
                versionWarned = true
                Log.e(p.message ?: "Clikgate SDK ${ownVersion()} is blocked; only basic calls are made. Update the SDK.")
            }
        }
    }

    private fun configRequest(): ApiRequest {
        val region = consentValues.region
        val path = if (region != null) "/v1/sdk/config?region_hint=${urlEncode(region)}" else "/v1/sdk/config"
        // Nothing identifying while buffering or denied, nor before the SDK knows whether consent is
        // required (first launch, attribution not granted yet): no installation id header.
        val unknownRequirement = Consent.required(featureConfig.consent, consentValues.region) == null &&
            consentValues.attribution != ConsentState.GRANTED
        return ApiRequest("GET", path, anonymous = storage.trackingEnabled && (gate() != Gate.ALLOWED || unknownRequirement))
    }

    /**
     * The `consent` object for request bodies. [optedOut]: the opted-out first `/install`, which says
     * so with every purpose `denied` (the SDK doesn't send `tracking_allowed`).
     */
    private fun consentBody(optedOut: Boolean = false): JSONObject =
        if (optedOut) consentValues.copy(analytics = ConsentState.DENIED, attribution = ConsentState.DENIED,
            adUserData = ConsentState.DENIED, adPersonalization = ConsentState.DENIED).json()
        else consentValues.json()

    private fun bufferForConsent() {
        if (storage.consentPendingSince == 0L) storage.consentPendingSince = deps.clock()
        expireConsentBuffer()
    }

    /** Buffer limits while consent is unknown: `buffer_max_days` (rolling) and `buffer_max_events`. */
    private fun expireConsentBuffer() {
        val c = featureConfig.consent
        val days = c?.bufferMaxDays ?: 7
        val dropped = queue.dropOlderThan(isoTimestamp(deps.clock() - TimeUnit.DAYS.toMillis(days.toLong())))
        if (dropped > 0) Log.i("Consent still unknown: dropped $dropped buffered event(s) older than $days days")
        queue.trimTo(c?.bufferMaxEvents ?: 1000)
    }

    /** Consent denied (required region): drop everything buffered. */
    private fun dropConsentBuffer() {
        if (queue.count() > 0) Log.i("Consent denied: dropping ${queue.count()} buffered event(s)")
        queue.clear()
        refuseAllGoals("consent_denied")
        consentBufferedUrls.clear()
        pendingUrls.clear()
        openPending = null
        launchUrl = null
        pendingOpenClickIds = null
        storage.consentPendingSince = 0
        if (!storage.installDone && storage.referrerJson != null) {
            // Kept first-launch data goes too; Play keeps the referrer for 90 days if consent comes later.
            storage.referrerJson = null
            storage.referrerDone = false
            referrerAttempted = false
        }
    }

    private fun maybeSendInstallPing() {
        if (storage.installPingSent || pingInFlight || featureConfig.consent?.anonymousCounts != true || !allows("install_ping")) return
        pingInFlight = true
        val body = JSONObject()
            .put("platform", "android")
            .put("app_version", deps.device.appVersion)
            .put("sdk_version", nativeVersion)
            .put("consent", consentBody())
        send(ApiRequest("POST", "/v1/sdk/install-ping", body, anonymous = true), maxAttempts = 5) { r ->
            pingInFlight = false
            if (r is ApiResult.Success) storage.installPingSent = true
        }
    }

    private fun sendConsent() {
        consentInFlight = true
        val sent = consentValues
        send(ApiRequest("POST", "/v1/sdk/consent", JSONObject().put("consent", consentBody())), maxAttempts = 5) { r ->
            consentInFlight = false
            if (consentValues == sent && (r is ApiResult.Success || (r is ApiResult.Failure && !r.retryable))) storage.consentSendPending = false
            if (r is ApiResult.Success) pump()
        }
    }

    fun setConsent(analytics: ConsentState?, attribution: ConsentState?, adUserData: ConsentState?, adPersonalization: ConsentState?) = runSerial {
        val old = consentValues
        val next = old.copy(
            analytics = analytics ?: old.analytics,
            attribution = attribution ?: old.attribution,
            adUserData = adUserData ?: old.adUserData,
            adPersonalization = adPersonalization ?: old.adPersonalization,
        )
        if (next == old && old.updatedAt != null) return@runSerial
        updateConsent(next.copy(updatedAt = isoTimestamp(deps.clock())), regionChanged = false)
    }

    fun setConsentRegion(region: String?) = runSerial {
        if (region == consentValues.region) return@runSerial
        updateConsent(consentValues.copy(region = region), regionChanged = true)
    }

    private fun updateConsent(next: ConsentValues, regionChanged: Boolean) {
        consentValues = next
        storage.consentJson = next.json().toString()
        storage.consentSendPending = true
        installStopped = false
        if (regionChanged && configReady) refreshConfig() else pump()
    }

    fun getConsent(): ClikgateConsent {
        val v = consentValues
        return ClikgateConsent(v.analytics, v.attribution, v.adUserData, v.adPersonalization, v.region,
            Consent.required(featureConfig.consent, v.region))
    }

    /** `attributionMetadata()`: latest matched deep link, else the install attribution. Any thread. */
    fun attributionMetadata(): Map<String, String> {
        if (!storage.trackingEnabled) return emptyMap()
        if (consentRequired() && consentValues.attribution != ConsentState.GRANTED) return emptyMap()
        val last = storage.lastClickJson?.let { try { JSONObject(it) } catch (_: Exception) { null } }
        val click: String?
        val link: String?
        if (last != null) {
            click = last.str("click_id")
            link = last.str("link_id")
        } else {
            val a = currentAttribution()
            click = a.clickId
            link = a.link?.id
        }
        val out = LinkedHashMap<String, String>()
        click?.let { out["cg_click_id"] = it }
        link?.let { out["cg_link_id"] = it }
        return out
    }

    // ------------------------------------------------------------------ Firebase forwarding

    fun enableFirebaseForwarding(options: FirebaseForwardingOptions) = runSerial {
        firebaseOptions = options
        pump()
    }

    private fun firebase(): FirebaseAnalyticsBridge? {
        if (firebaseOptions == null || !config.firebase.enabled || blocked) return null
        if (!storage.trackingEnabled || !purposeAllowed(consentValues.analytics)) return null
        val f = deps.firebase ?: return null
        if (!f.isAvailable()) {
            Log.d("Firebase forwarding enabled but Firebase Analytics isn't in the app")
            return null
        }
        return f
    }

    private fun maybeLogFirebaseAttribution() {
        if (storage.firebaseAttributionLogged || !storage.installDone || pollingActive) return
        val f = firebase() ?: return
        val opts = firebaseOptions ?: return
        val a = storage.attributionJson?.let { try { JSONObject(it) } catch (_: Exception) { null } } ?: return
        val status = a.str("status")
        if (status != ClikgateAttribution.STATUS_ATTRIBUTED && status != ClikgateAttribution.STATUS_ORGANIC) return
        val organic = status == ClikgateAttribution.STATUS_ORGANIC
        if (opts.logAttributionEvent && config.firebase.logAttributionEvent) {
            val p = LinkedHashMap<String, Any?>()
            p["cg_source"] = a.str("source")
            p["cg_medium"] = a.str("medium")
            p["cg_campaign"] = a.str("campaign")
            p["cg_channel"] = if (organic) "organic" else a.str("channel")
            p["cg_link_id"] = a.optJSONObject("link")?.str("id")
            p["cg_match_type"] = a.str("match_type")
            f.logEvent("clikgate_attribution", FirebaseLimits.params(p.filterValues { it != null }))
        }
        if (opts.setUserProperties && config.firebase.setUserProperties) {
            (if (organic) "organic" else a.str("source"))?.let { f.setUserProperty("cg_first_source", it.take(FirebaseLimits.MAX_USER_PROPERTY_VALUE)) }
            a.str("campaign")?.let { f.setUserProperty("cg_first_campaign", it.take(FirebaseLimits.MAX_USER_PROPERTY_VALUE)) }
        }
        storage.firebaseAttributionLogged = true
    }

    private fun appInstanceIdWanted(): Boolean =
        firebase() != null && config.firebase.reportAppInstanceId

    private fun maybeFetchAppInstanceId(then: (() -> Unit)? = null) {
        if (appInstanceIdFetched || !appInstanceIdWanted()) {
            then?.invoke()
            return
        }
        appInstanceIdFetched = true
        appInstanceIdFetching = true
        var done = false
        val timeout = serial.schedule({
            if (!done) {
                done = true
                appInstanceIdFetching = false
                if (then != null) then() else pump()
            }
        }, deps.appInstanceIdWaitMs, TimeUnit.MILLISECONDS)
        deps.firebase?.appInstanceId { id ->
            runSerial {
                if (id != null) appInstanceId = id.take(128)
                if (!done) {
                    done = true
                    appInstanceIdFetching = false
                    timeout.cancel(false)
                    if (then != null) then() else pump()
                } else if (id != null) {
                    pump()
                }
            }
        }
    }

    /** The app instance id to send (only when it changed since the last acknowledged send). */
    private fun appInstanceIdToSend(): String? =
        appInstanceId?.takeIf { appInstanceIdWanted() && it != storage.appInstanceIdSent }

    // ------------------------------------------------------------------ config

    private fun loadConfig() {
        if (configInFlight) return
        val cached = storage.configJson
        val age = deps.clock() - storage.configFetchedAt
        if (cached != null && age in 0 until CONFIG_TTL_MS) {
            applyConfig(cached)
            pump()
            return
        }
        configInFlight = true
        send(configRequest(), maxAttempts = 1) { r ->
            configInFlight = false
            when (r) {
                is ApiResult.Success -> {
                    storage.configJson = r.body.toString()
                    storage.configFetchedAt = deps.clock()
                    disabledByServer.clear()
                    applyConfig(r.body.toString())
                }
                is ApiResult.Failure -> {
                    Log.d("Config fetch failed (${r.error.code}); using ${if (cached != null) "cached" else "default"} config")
                    if (cached != null) applyConfig(cached) else configReady = true
                }
            }
            pump()
        }
    }

    private fun applyConfig(json: String) {
        config = try {
            SdkConfig.parse(JSONObject(json))
        } catch (_: Exception) {
            SdkConfig.DEFAULT
        }
        featureConfig = config
        configReady = true
        linkDomains = optionDomains + config.linkDomains
        for (d in config.linkDomains) {
            if (d !in optionDomains && warnedDomains.add(d)) {
                Log.w("Link domain $d is listed by Clikgate but not in ClikgateOptions.linkDomains. Android opens the app only " +
                    "for hosts in your intent filters: add an autoVerify intent filter for https://$d (and add it to linkDomains).")
            }
        }
        checkVersionPolicy()
        if (config.privateMode) warnPrivateMode()
        if (candidateUrls.isNotEmpty()) {
            val urls = ArrayList(candidateUrls)
            candidateUrls.clear()
            for (u in urls) if (isClikgateUrl(Uri.parse(u))) enqueueUrl(u)
        }
        if (!foreground) return
        restartFlushTimer()
    }

    /**
     * Re-fetches `/config` in the background (after a `feature_disabled` answer the cached copy is
     * stale). Serial thread.
     */
    private fun refreshConfig() {
        if (configInFlight || invalidKey) return
        configInFlight = true
        send(configRequest(), maxAttempts = 1) { r ->
            configInFlight = false
            if (r is ApiResult.Success) {
                storage.configJson = r.body.toString()
                storage.configFetchedAt = deps.clock()
                // A fresh config is authoritative again (the feature may have been switched back on).
                disabledByServer.clear()
                applyConfig(r.body.toString())
            }
            pump()
        }
    }

    /** `Clikgate.isFeatureEnabled`: cached config, else catalogue defaults. Any thread. */
    fun isFeatureEnabled(key: String): Boolean = key !in disabledByServer && featureConfig.isFeatureEnabled(key)

    // ------------------------------------------------------------------ install

    private fun prepareInstall() {
        installInFlight = true
        if (!storage.referrerDone && !referrerAttempted) {
            InstallReferrerFetcher(deps.referrerSource, serial, deps.referrerWaitsMs).fetch { json, final ->
                referrerAttempted = true
                if (json != null) storage.referrerJson = json.toString()
                if (final) storage.referrerDone = true
                attestThenInstall()
            }
        } else {
            attestThenInstall()
        }
    }

    private fun attestationEnabled(): Boolean =
        options.attestation == com.clikgate.Attestation.PLAY_INTEGRITY_IF_AVAILABLE &&
            config.playIntegrity != "off" && !blocked && identityChecksAllowed() && deps.attestation?.isAvailable() == true

    private fun attestThenInstall() {
        if (blocked) {
            sendInstall(blockedInstallBody())
            return
        }
        maybeFetchAppInstanceId {
            if (!attestationEnabled()) {
                sendInstall(installBody(null))
            } else {
                attest { att -> sendInstall(installBody(att)) }
            }
        }
    }

    /** challenge -> provider token; [cb] gets the `attestation` object or null (serial thread). */
    private fun attest(cb: (JSONObject?) -> Unit) {
        val provider = deps.attestation ?: return cb(null)
        send(ApiRequest("POST", "/v1/sdk/attest/challenge", JSONObject()), maxAttempts = 2) { r ->
            if (r !is ApiResult.Success) return@send cb(null)
            val challenge = r.body.str("challenge")
            val nonce = r.body.str("nonce")
            if (challenge == null || nonce == null) return@send cb(null)
            var finished = false
            val timeout = serial.schedule({ if (!finished) { finished = true; cb(null) } }, deps.attestationTimeoutMs, TimeUnit.MILLISECONDS)
            provider.token(nonce, options.cloudProjectNumber ?: config.cloudProjectNumber) { token ->
                runSerial {
                    if (finished) return@runSerial
                    finished = true
                    timeout.cancel(false)
                    cb(token?.let {
                        JSONObject().put("type", provider.type).put("token", it.token).put("challenge", challenge)
                            .put("request_type", it.requestType)
                    })
                }
            }
        }
    }

    private fun optedOutInstallBody(): JSONObject = JSONObject().apply {
        put("installation_id", installationId)
        put("app_version", deps.device.appVersion)
        put("sdk_version", nativeVersion)
        put("platform", "android")
        put("consent", consentBody(optedOut = true))
    }

    /** Version policy `blocked`: required fields, consent, referrer and launch URL only. */
    private fun blockedInstallBody(): JSONObject = JSONObject().apply {
        put("installation_id", installationId)
        put("app_version", deps.device.appVersion)
        put("sdk_version", nativeVersion)
        put("platform", "android")
        put("launch_url", launchUrl ?: JSONObject.NULL)
        put("install_referrer", storage.referrerJson?.let { JSONObject(it) } ?: JSONObject.NULL)
        put("consent", consentBody())
    }

    internal fun installBody(attestation: JSONObject?): JSONObject = JSONObject().apply {
        val d = deps.device
        put("installation_id", installationId)
        put("app_version", d.appVersion)
        put("sdk_version", nativeVersion)
        put("platform", "android")
        put("os_version", d.osVersion)
        put("device_model", if (config.restrictedMode) JSONObject.NULL else (d.deviceModel ?: JSONObject.NULL))
        put("locale", d.locale)
        put("timezone", d.timezone)
        // Screen size is a probabilistic-matching signal: only when the server enables it and
        // attribution consent allows it.
        if (config.probabilisticMatching && purposeAllowed(consentValues.attribution)) put("screen", d.screen() ?: JSONObject.NULL)
        val url = launchUrl
        put("launch_url", url ?: JSONObject.NULL)
        put("install_referrer", storage.referrerJson?.let { JSONObject(it) } ?: JSONObject.NULL)
        put("installer_package", d.installerPackage() ?: JSONObject.NULL)
        put("push", currentPushJson() ?: JSONObject.NULL)
        if (attestation != null) put("attestation", attestation)
        put("consent", consentBody())
        val referrer = storage.referrerJson?.let { try { JSONObject(it).str("referrer") } catch (_: Exception) { null } }
        (ClickIds.fromUrl(url) ?: ClickIds.fromReferrer(referrer))?.let { put("google_click_ids", it) }
        appInstanceIdToSend()?.let { put("app_instance_id", it) }
        // Fraud signals (hints): computed once per request body; a failing check omits its field.
        signal { d.isEmulator() }?.let { put("is_emulator", it) }
        signal { d.isRooted() }?.let { put("is_rooted", it) }
    }

    private inline fun signal(check: () -> Boolean): Boolean? = try {
        check()
    } catch (_: Exception) {
        null
    }

    private fun sendInstall(body: JSONObject, optedOut: Boolean = false) {
        installInFlight = true
        installRequestBuilt = true
        val sentUrl = body.str("launch_url")
        val sentConsent = !optedOut
        val sentPushHash = body.optJSONObject("push")?.let { hash(it.optString("provider") + it.optString("token")) }
        var sentAttestation = body.has("attestation")
        // Attestation challenges are single use and expire after 5 minutes: retries go without
        // it (the weekly /attest re-attestation covers the installation later).
        val dropAttestation: (ApiRequest) -> ApiRequest = { req ->
            if (req.body?.has("attestation") == true) {
                sentAttestation = false
                ApiRequest(req.method, req.path, JSONObject(req.body.toString()).apply { remove("attestation") }, req.headers, req.anonymous)
            } else {
                req
            }
        }
        send(ApiRequest("POST", "/v1/sdk/install", body), maxAttempts = Int.MAX_VALUE, forRetry = dropAttestation) { r ->
            installInFlight = false
            installRequestBuilt = false
            when (r) {
                is ApiResult.Success -> {
                    if (sentUrl != null && launchUrl == sentUrl) launchUrl = null
                    if (sentPushHash != null) storage.pushSentHash = sentPushHash
                    if (sentAttestation) storage.lastAttestedAt = deps.clock()
                    body.str("app_instance_id")?.let { storage.appInstanceIdSent = it }
                    // The opted-out install sent every purpose denied, not the app's values: those go
                    // through /consent once tracking is back on.
                    storage.consentSendPending = if (optedOut) storage.consentSendPending || consentValues.json().toString() != body.optJSONObject("consent")?.toString()
                    else storage.consentSendPending && body.optJSONObject("consent")?.toString() != consentBody().toString()
                    if (sentConsent != storage.trackingEnabled) storage.pendingOptOut = !storage.trackingEnabled
                    else if (!sentConsent) storage.pendingOptOut = null
                    // A launch URL that arrived after the request was built goes through /resolve.
                    launchUrl?.let { pendingUrls.add(it); launchUrl = null }
                    handleInstallResponse(r.body, body)
                    // A gated launch URL (any domain) gets the same handling as a gated
                    // /resolve answer: the password page in the system browser, or the blocked result.
                    // Otherwise a shared-domain launch URL the install didn't match may be another
                    // organisation's link: /resolve it, which hands it to the browser when unmatched.
                    // One tap is one click: never when the install matched the launch URL
                    // (`status: matched`): /install already recorded its click, and /resolve would record another.
                    if (sentUrl != null && Json.isGated(r.body)) {
                        if (!launchUrlDeliveredLocally) deliverGated(r.body, sentUrl)
                    } else if (sentUrl != null && !launchUrlDeliveredLocally && options.platformDomainBrowserFallback &&
                        SharedDomains.host(sentUrl) != null && Json.installDeepLink(r.body) == null &&
                        r.body.str("status") != "matched" &&
                        r.body.optJSONObject("attribution")?.str("status") != ClikgateAttribution.STATUS_PENDING
                    ) {
                        pendingUrls.add(sentUrl)
                    }
                }
                is ApiResult.Failure -> {
                    if (r.error.code != "installation_unknown" && r.error.code != ClikgateError.SDK_DISABLED) {
                        installStopped = true
                        Log.e("Install failed: ${r.error.code} (${r.error.message}); retrying on next launch")
                        installWaiters.toList().forEach { it.complete(false) }
                        installWaiters.clear()
                    }
                }
            }
            pump()
        }
    }

    private fun handleInstallResponse(body: JSONObject, request: JSONObject) {
        val installId = body.str("install_id")
        val attribution = body.optJSONObject("attribution")
        storage.installId = installId
        if (attribution != null) storage.attributionJson = attribution.toString()
        storage.installDone = true
        storage.lastOpenAt = deps.clock()
        Log.i("Install recorded: ${attribution?.str("status") ?: "unknown"}")

        installWaiters.toList().forEach { it.complete(true) }
        installWaiters.clear()

        // A gated launch URL never routes into the app, whatever else the answer carries.
        if (storage.trackingEnabled && !deferredDelivered && !Json.isGated(body)) {
            Json.installDeepLink(body)?.let {
                deferredDelivered = true
                // Already delivered locally while buffering / blocked: don't route twice.
                if (!(launchUrlDeliveredLocally && !it.isDeferred)) {
                    dispatcher.dispatch(it)
                    reportHandled(it, body)
                }
            }
        }

        val retryAfter = body.optLong("retry_after_ms", -1).takeIf { !body.isNull("retry_after_ms") && it >= 0 }
        val pending = attribution?.str("status") == ClikgateAttribution.STATUS_PENDING
        if (retryAfter != null && installPolls < MAX_INSTALL_POLLS && storage.trackingEnabled) {
            installPolls++
            pollingActive = true
            serial.schedule({ pollInstall(request) }, retryAfter, TimeUnit.MILLISECONDS)
            if (!pending) resolveAttributionWaiters()
        } else {
            pollingActive = false
            resolveAttributionWaiters()
        }
        maybeLogFirebaseAttribution()
    }

    private fun pollInstall(original: JSONObject) {
        // Never resend a (single-use) attestation challenge on polls.
        val request = JSONObject(original.toString()).apply { remove("attestation") }
        send(ApiRequest("POST", "/v1/sdk/install", request), maxAttempts = 3) { r ->
            if (r is ApiResult.Success) {
                handleInstallResponse(r.body, request)
            } else {
                pollingActive = false
                resolveAttributionWaiters()
            }
        }
    }

    // ------------------------------------------------------------------ attribution

    fun currentAttribution(): ClikgateAttribution {
        val json = storage.attributionJson?.let { try { JSONObject(it) } catch (_: Exception) { null } }
        return Json.attribution(json, storage.installId)
    }

    fun attribution(cb: (ClikgateAttribution) -> Unit) = runSerial {
        val current = currentAttribution()
        if (storage.installDone && !(pollingActive && current.status == ClikgateAttribution.STATUS_PENDING)) {
            cb(current)
            return@runSerial
        }
        val w = Waiter(cb)
        w.timeout = serial.schedule({
            attributionWaiters.remove(w)
            w.complete(currentAttribution())
        }, options.deferredDeepLinkTimeoutMs, TimeUnit.MILLISECONDS)
        attributionWaiters.add(w)
        pump()
    }

    private fun resolveAttributionWaiters() {
        val a = currentAttribution()
        attributionWaiters.toList().forEach { it.complete(a) }
        attributionWaiters.clear()
    }

    // ------------------------------------------------------------------ URLs / deep links

    fun isClikgateUrl(uri: Uri): Boolean {
        val scheme = uri.scheme?.lowercase() ?: return false
        if (scheme == "http" || scheme == "https") {
            val host = uri.host?.lowercase() ?: return false
            return host in linkDomains
        }
        // Custom URI scheme: only links carrying a Clikgate click id.
        return try {
            uri.isHierarchical && !uri.getQueryParameter("cg_click_id").isNullOrEmpty()
        } catch (_: Exception) {
            false
        }
    }

    /** Called with a URL the app was opened with. Returns true if it's a Clikgate URL. */
    fun handleUrl(url: String): Boolean {
        val uri = Uri.parse(url)
        val known = isClikgateUrl(uri)
        runSerial {
            if (known) {
                enqueueUrl(url)
            } else if (!configReady && (uri.scheme == "http" || uri.scheme == "https")) {
                candidateUrls.add(url)
            }
        }
        return known
    }

    private fun enqueueUrl(url: String) {
        if (!storage.trackingEnabled) {
            // Opted out: no server call; hand the app the URL itself so routing still works.
            dispatcher.dispatch(localDeepLink(url))
            return
        }
        val installSlot = !storage.installDone && !installRequestBuilt && launchUrl == null
        when (gate()) {
            Gate.DENIED -> {
                dispatcher.dispatch(localDeepLink(url))
                return
            }
            Gate.PENDING -> {
                // Buffering for consent: route locally now, tell Clikgate after grant.
                dispatcher.dispatch(localDeepLink(url))
                if (installSlot) {
                    launchUrl = url
                    launchUrlDeliveredLocally = true
                } else {
                    consentBufferedUrls.add(url)
                    while (consentBufferedUrls.size > 10) consentBufferedUrls.removeAt(0)
                }
                ClickIds.fromUrl(url)?.let { pendingOpenClickIds = it }
                pump()
                return
            }
            Gate.ALLOWED -> Unit
        }
        if (installSlot) {
            launchUrl = url
        } else {
            pendingUrls.add(url)
        }
        pump()
    }

    private fun localDeepLink(url: String): ClikgateDeepLink {
        val uri = Uri.parse(url)
        val data = LinkedHashMap<String, Any?>()
        try {
            for (name in uri.queryParameterNames) data[name] = uri.getQueryParameter(name)
        } catch (_: Exception) {
        }
        return ClikgateDeepLink(url, uri.path, data, false, uri.getQueryParameter("cg_click_id"), null, null, null)
    }

    private fun sendResolve(url: String, deliver: Boolean = true) {
        val body = JSONObject().put("url", url).put("consent", consentBody())
        ClickIds.fromUrl(url)?.let {
            body.put("google_click_ids", it)
            pendingOpenClickIds = it
        }
        send(ApiRequest("POST", "/v1/sdk/resolve", body), maxAttempts = 5) { r ->
            when (r) {
                // The link gates run in /resolve. A gated answer never routes into the app,
                // whatever else it carries.
                is ApiResult.Success -> if (Json.isGated(r.body)) {
                    if (deliver) deliverGated(r.body, url)
                } else if (r.body.optBoolean("matched", false)) {
                    val dl = Json.resolveDeepLink(r.body, url)
                    if (dl.clickId != null) {
                        storage.lastClickJson = JSONObject().put("click_id", dl.clickId).put("link_id", dl.link?.id ?: JSONObject.NULL).toString()
                    }
                    if (deliver) {
                        dispatcher.dispatch(dl)
                        reportHandled(dl, r.body)
                    }
                } else if (deliver && options.platformDomainBrowserFallback && SharedDomains.host(url) != null) {
                    handOff(url)
                } else {
                    Log.d("URL is not a Clikgate link of this app")
                }
                is ApiResult.Failure -> Log.w("Resolving a link failed: ${r.error.code}")
            }
        }
    }

    /**
     * `deeplink_handled` (the live check) with the delivered link's path (IDs → `:id`), only with a test
     * key, while [response] says the dashboard's debug view is open, or (live mode too) when
     * [response] says the opening click is an App banner tap measuring the right screen (`measure_right_screen`;
     * the click is sent as `click_id`). Never queued, counted or a goal; one retry, then dropped.
     */
    private fun reportHandled(link: ClikgateDeepLink, response: JSONObject) {
        val bannerClick = if (response.optBoolean("measure_right_screen")) response.str("click_id") else null
        if (!testMode && !response.optBoolean("debug_view") && bannerClick == null) return
        if (gate() != Gate.ALLOWED || !allows("deeplink_handled")) return
        val path = link.path ?: link.url?.let { Uri.parse(it).encodedPath } ?: ""
        val body = JSONObject().put("path", DeepLinkPath.clean(path)).put("is_deferred", link.isDeferred)
        if (bannerClick != null) body.put("click_id", bannerClick)
        send(ApiRequest("POST", "/v1/sdk/deeplink-handled", body), maxAttempts = 2) {
            if (it is ApiResult.Failure) Log.d("deeplink_handled not sent: ${it.error.code}")
        }
    }

    /** A gated `/resolve` or `/install` answer for [url], the URL that opened the app. */
    private fun deliverGated(response: JSONObject, url: String) {
        if (response.str("status") == "password_required") openPasswordPage(response.str("web_url") ?: url)
        else dispatcher.dispatch(Json.blockedDeepLink(url, response.str("block_message") ?: ""))
    }

    /**
     * A password link: its password page in the system browser (an explicit browser
     * package, no Custom Tabs; never an implicit intent, which this app's App Links would catch). No
     * deep link, no handoff event. Logs name the host only.
     */
    private fun openPasswordPage(url: String) {
        val host = Uri.parse(url).host
        main.post {
            if (deps.browser?.openExternal(url) == true) Log.i("$host link needs a password; opened it in the browser")
            else Log.w("$host link needs a password and no browser could open it")
        }
    }

    /**
     * A shared-domain link of another organisation: open it in an in-app browser (never through an
     * implicit intent, which could loop back into this app's App Links) and tell the app.
     */
    private fun handOff(url: String) {
        val host = SharedDomains.host(url) ?: return
        main.post {
            if (deps.browser?.open(url) == true) {
                Log.i("$host link isn't this app's; opened it in the browser")
                handoffs.dispatch(ClikgateBrowserHandoff(url, host))
            } else {
                Log.w("$host link isn't this app's and no browser could open it")
            }
        }
    }

    // ------------------------------------------------------------------ lifecycle

    fun onForeground() {
        val now = deps.clock()
        runSerial { foregroundAt(now) }
    }

    private fun foregroundAt(now: Long) {
        foreground = true
        if (!seenFirstForeground) {
            seenFirstForeground = true
            if (installDoneAtLaunch) openPending = true
        } else if (now - storage.lastBackgroundAt >= TimeUnit.MINUTES.toMillis(config.sessionTimeoutMinutes.toLong())) {
            if (storage.installDone) openPending = false
        }
        restartFlushTimer()
        pump()
    }

    fun onBackground() {
        val now = deps.clock()
        runSerial { backgroundAt(now) }
    }

    private fun backgroundAt(now: Long) {
        foreground = false
        storage.lastBackgroundAt = now
        flushTimer?.cancel(false)
        flushTimer = null
        flushRequested = true
        pump()
        if (queue.count() > 0 && storage.trackingEnabled) deps.background.scheduleFlush()
    }

    private fun restartFlushTimer() {
        flushTimer?.cancel(false)
        val interval = config.flushIntervalSeconds.toLong()
        flushTimer = serial.scheduleWithFixedDelay({
            if (queue.count() > 0) {
                flushRequested = true
                pump()
            }
        }, interval, interval, TimeUnit.SECONDS)
    }

    private fun sendOpen(cold: Boolean) {
        openInFlight = true
        val body = JSONObject()
            .put("app_version", deps.device.appVersion)
            .put("os_version", deps.device.osVersion)
            .put("is_cold_start", cold)
            .put("consent", consentBody())
        val clickIds = pendingOpenClickIds
        if (clickIds != null && !blocked) body.put("google_click_ids", JSONObject(clickIds.toString()).put("source", "deep_link"))
        val instanceId = appInstanceIdToSend()
        if (instanceId != null) body.put("app_instance_id", instanceId)
        send(ApiRequest("POST", "/v1/sdk/open", body), maxAttempts = 5) { r ->
            openInFlight = false
            if (openPending == cold) openPending = null
            if (r is ApiResult.Success) {
                storage.lastOpenAt = deps.clock()
                if (pendingOpenClickIds === clickIds) pendingOpenClickIds = null
                if (instanceId != null) storage.appInstanceIdSent = instanceId
            }
            pump()
        }
    }

    // ------------------------------------------------------------------ goals

    /** Validates and enqueues a goal. Returns an error for invalid input. */
    fun goal(
        key: String,
        value: java.math.BigDecimal?,
        currency: String?,
        reference: String?,
        provider: String?,
        isFirst: Boolean?,
        label: String?,
        onResult: GoalResultListener?,
        at: Long? = null,
    ): ClikgateError? {
        val payload = try {
            Goals.build(key, value, currency, reference, provider, isFirst, currentClickId(), at ?: deps.clock())
                .also { o -> checkLabel(label, "goal(\"$key\")")?.let { o.put("label", it) } }
        } catch (e: ClikgateError) {
            // Never log the reference or the value.
            Log.e("goal(\"$key\") rejected: ${e.message}")
            deliver(onResult, Goals.refused(ClikgateError.INVALID_ARGUMENT))
            return e
        }
        enqueueGoal(payload, Goals.dedupeKey(key, payload.getString("reference")), "goal(\"$key\")", onResult)
        return null
    }

    /** Goals: queued (consent gate, opt-out, deep-link-only mode), deduped by (key, reference). */
    private fun enqueueGoal(payload: JSONObject, dedupe: String, label: String, onResult: GoalResultListener?) {
        if (attributionOff()) return deliver(onResult, Goals.refused("feature_disabled"))
        runSerial {
            if (!storage.trackingEnabled) return@runSerial deliver(onResult, Goals.refused("opted_out"))
            val gate = gate()
            // Consent denied in a required region: never sent.
            if (gate == Gate.DENIED) return@runSerial deliver(onResult, Goals.refused("consent_denied"))
            if (onResult != null) goalListeners.getOrPut(dedupe) { java.util.Collections.synchronizedList(ArrayList()) }.add(onResult)
            if (queue.contains(dedupe)) {
                Log.d("$label with this reference is already queued; ignored")
                return@runSerial
            }
            val pending = gate == Gate.PENDING
            val max = if (pending) minOf(config.maxQueueEvents, featureConfig.consent?.bufferMaxEvents ?: 1000) else config.maxQueueEvents
            val count = queue.add(payload, max, config.maxQueueBytes, dedupe)
            if (pending) {
                bufferForConsent()
            } else if (count >= config.flushAtCount) {
                flushRequested = true
                pump()
            }
        }
    }

    private fun deliver(listener: GoalResultListener?, result: GoalResult) {
        if (listener == null) return
        main.post {
            try {
                listener.onResult(result)
            } catch (t: Throwable) {
                Log.e("Goal result listener threw", t)
            }
        }
    }

    /** Delivers [result] for the queued goal [item] (and logs the test-mode lines). */
    private fun resolveGoal(item: JSONObject, result: GoalResult) {
        val key = item.optString("goal")
        if (testMode && result.goalKind == GoalKind.PAYMENT) {
            if (result.status == GoalStatus.WAITING) Log.w("$key is a Payment goal: waiting for confirmation")
            if (result.valueIgnored) Log.w("$key is a Payment goal: the value was ignored (the amount comes from the confirmation)")
        }
        // The organisation accepts only goals it has set up: final, never retried. The goal name only, debug builds only.
        if (result.status == GoalStatus.REFUSED && result.reason == Goals.UNKNOWN_GOAL && deps.device.isDebuggableApp) {
            Log.w("Goal `$key` isn't set up in Clikgate")
        }
        goalListeners.remove(Goals.dedupeKey(key, item.optString("reference")))?.toList()?.forEach { deliver(it, result) }
    }

    /** The queue was cleared: every waiting listener gets a refusal. */
    private fun refuseAllGoals(reason: String) {
        for (k in goalListeners.keys.toList()) goalListeners.remove(k)?.toList()?.forEach { deliver(it, Goals.refused(reason)) }
    }

    /**
     * Deep-link-only mode (an app with attribution switched off):
     * `app_attribution` is off in the cached config or the server answered `feature_disabled` for
     * `/goals`. Logs the one-time "attribution is switched off" warning. Any thread.
     */
    private fun attributionOff(): Boolean {
        if (isFeatureEnabled(ClikgateFeatures.APP_ATTRIBUTION)) return false
        warnNeedsGrowth()
        return true
    }

    @Volatile
    private var needsGrowthWarned = false

    private fun warnNeedsGrowth() {
        if (needsGrowthWarned) return
        needsGrowthWarned = true
        Log.w("goal() is off for this app: app attribution is switched off, " +
            "so goals are not sent. Deep links keep working.")
    }

    /** `/goals` answered the `feature_disabled` body: mark attribution off, never retry. Serial thread. */
    private fun attributionDisabledByServer(body: JSONObject) {
        disabledByServer.add(body.str("feature") ?: ClikgateFeatures.APP_ATTRIBUTION)
        disabledByServer.add(ClikgateFeatures.APP_ATTRIBUTION)
        warnNeedsGrowth()
        refreshConfig()
    }

    /** The click a goal is attributed to: latest matched deep link, else the install's click. Any thread. */
    private fun currentClickId(): String? {
        val last = storage.lastClickJson?.let { try { JSONObject(it) } catch (_: Exception) { null } }
        return if (last != null) last.str("click_id") else currentAttribution().clickId
    }

    private fun flushGoals(batch: List<QueuedEvent>) {
        flushInFlight = true
        val body = JSONObject().put("goals", JSONArray().also { a -> batch.forEach { a.put(it.payload) } })
            .put("consent", consentBody())
        val req = ApiRequest("POST", "/v1/sdk/goals", body, mapOf("Idempotency-Key" to UUID.randomUUID().toString()))
        fun drop(msg: String) {
            Log.w(msg)
            queue.remove(batch.map { it.rowId })
            if (queue.count() > 0) flushRequested = true else notifyFlushWaiters(true)
        }
        send(req, maxAttempts = 5) { r ->
            flushInFlight = false
            when {
                r is ApiResult.Success && Json.isFeatureDisabled(r.body) -> {
                    attributionDisabledByServer(r.body)
                    queue.remove(batch.map { it.rowId })
                    batch.forEach { resolveGoal(it.payload, Goals.refused("feature_disabled")) }
                    if (queue.count() > 0) flushRequested = true else notifyFlushWaiters(true)
                }
                r is ApiResult.Success -> {
                    val rej = r.body.optJSONArray("rejected") ?: JSONArray()
                    if (rej.length() > 0) {
                        val codes = (0 until rej.length()).mapNotNull { rej.optJSONObject(it)?.str("code") }.toSortedSet()
                        Log.w("${rej.length()} goal(s) rejected by the server and dropped (${codes.joinToString()})")
                    }
                    queue.remove(batch.map { it.rowId })
                    resolveBatch(batch, r.body.optJSONArray("results"), rej)
                    if (queue.count() > 0) flushRequested = true else notifyFlushWaiters(true)
                }
                r is ApiResult.Failure && r.error.status == 422 -> {
                    batch.forEach { resolveGoal(it.payload, Goals.refused(r.error.code)) }
                    drop("Goal batch rejected (${r.error.code}); dropping ${batch.size} goal(s)")
                }
                r is ApiResult.Failure && r.error.status == 404 && r.error.code != "installation_unknown" -> {
                    if (!goalsUnsupportedWarned) {
                        goalsUnsupportedWarned = true
                        Log.w("This Clikgate server doesn't accept goals yet (404); dropping queued goals")
                    }
                    queue.remove(batch.map { it.rowId })
                    batch.forEach { resolveGoal(it.payload, Goals.refused(r.error.code)) }
                    if (queue.count() > 0) flushRequested = true else notifyFlushWaiters(true)
                }
                else -> {
                    if (storage.trackingEnabled) deps.background.scheduleFlush()
                    notifyFlushWaiters(false)
                }
            }
            pump()
        }
    }

    /**
     * Each sent goal's result: its `results[]` item (by `index`, else goal and reference); a
     * `rejected[]` item is refused with its code; an older server without `results` counted the rest.
     */
    private fun resolveBatch(batch: List<QueuedEvent>, results: JSONArray?, rejected: JSONArray) {
        fun find(a: JSONArray?, i: Int, item: JSONObject): JSONObject? {
            if (a == null) return null
            val all = (0 until a.length()).mapNotNull { a.optJSONObject(it) }
            return all.firstOrNull { it.has("index") && !it.isNull("index") && it.optInt("index", -1) == i }
                ?: all.firstOrNull { (!it.has("index") || it.isNull("index")) && it.optString("goal") == item.optString("goal") && it.optString("reference") == item.optString("reference") }
        }
        batch.forEachIndexed { i, e ->
            val res = find(results, i, e.payload)
            val rej = find(rejected, i, e.payload)
            val result = when {
                res != null -> Goals.result(res)
                rej != null -> Goals.refused(rej.optString("code").ifEmpty { "rejected" })
                else -> GoalResult(GoalStatus.COUNTED, null, null, false)
            }
            resolveGoal(e.payload, result)
        }
    }

    private fun flush() {
        if (flushInFlight) return
        if (!storage.installDone || !storage.trackingEnabled || storage.pendingOptOut != null) return
        if (gate() != Gate.ALLOWED) return
        var batch = queue.peek(config.maxBatchSize)
        flushRequested = false
        if (batch.isNotEmpty() && attributionOff()) {
            // Deep-link-only mode: what was queued before the config said so is dropped, no network.
            queue.clear()
            refuseAllGoals("feature_disabled")
            return notifyFlushWaiters(true)
        }
        // goal() is the only method. App events queued by an earlier development build (the queue is
        // persisted) are dropped without a network call: there is no events endpoint any more.
        val legacy = batch.filterNot { Goals.isGoal(it.payload) }
        if (legacy.isNotEmpty()) {
            Log.d("Dropping ${legacy.size} queued app event(s) from an earlier SDK build: goal() is the only method")
            queue.remove(legacy.map { it.rowId })
            batch = batch.filter { Goals.isGoal(it.payload) }
            if (batch.isEmpty()) {
                flushRequested = queue.count() > 0
                return if (flushRequested) pump() else notifyFlushWaiters(true)
            }
        }
        if (batch.isEmpty()) return notifyFlushWaiters(true)
        if (!allows("goals")) {
            Log.w("This Clikgate SDK version is blocked for goals; dropping ${batch.size} goal(s)")
            queue.remove(batch.map { it.rowId })
            batch.forEach { resolveGoal(it.payload, Goals.refused("sdk_version_blocked")) }
            flushRequested = queue.count() > 0
            return if (flushRequested) pump() else notifyFlushWaiters(true)
        }
        flushGoals(batch)
    }

    private fun notifyFlushWaiters(ok: Boolean) {
        val ws = ArrayList(flushWaiters)
        flushWaiters.clear()
        ws.forEach { it(ok) }
    }

    /** Flushes from a WorkManager worker thread; true when the queue is empty afterwards. */
    fun flushBlocking(timeoutMs: Long): Boolean {
        val latch = CountDownLatch(1)
        var ok = false
        runSerial {
            if (!storage.installDone || !storage.trackingEnabled) {
                ok = !storage.trackingEnabled
                latch.countDown()
                return@runSerial
            }
            flushWaiters.add { success -> ok = success && queue.count() == 0; latch.countDown() }
            flushRequested = true
            pump()
        }
        latch.await(timeoutMs, TimeUnit.MILLISECONDS)
        return ok
    }

    // ------------------------------------------------------------------ installation ID

    /**
     * This installation's ID for the app's own server (identity Path B), on the main thread.
     * Null when tracking is off: opted out, consent denied (or not given yet) where it's required, or deep-link-only
     * mode. On a first launch it waits for the first config answer (one attempt, so offline it answers at once;
     * at most [INSTALLATION_ID_WAIT_MS]) so the consent and attribution switches are known. Never logged in full.
     */
    fun installationIdForApp(cb: (String?) -> Unit) = runSerial {
        fun answer() {
            val id = if (!storage.trackingEnabled || !isFeatureEnabled(ClikgateFeatures.APP_ATTRIBUTION) || gate() != Gate.ALLOWED) {
                null
            } else {
                installationId
            }
            main.post { cb(id) }
        }
        if (configReady || !storage.trackingEnabled) return@runSerial answer()
        val w = Waiter<Unit> { answer() }
        w.timeout = serial.schedule({
            installationIdWaiters.remove(w)
            w.complete(Unit)
        }, INSTALLATION_ID_WAIT_MS, TimeUnit.MILLISECONDS)
        installationIdWaiters.add(w)
        pump()
    }

    // ------------------------------------------------------------------ identify

    /**
     * identifyUser(): [customerSet] false keeps the stored customer ID; a null [customerId] clears it.
     * Nothing to send is a no-op. In private mode the customer ID and token are dropped on the device, and
     * the label too unless the organisation allows labels there.
     */
    fun identifyUser(label: String?, customerSet: Boolean, customerId: String?, identityToken: String?) = runSerial {
        val l = checkLabel(label, "identifyUser")
        val customer = customerSet || identityToken != null
        if (customer && featureConfig.privateMode) warnPrivateMode()
        if (l == null && (!customer || featureConfig.privateMode)) return@runSerial
        if (customer && !featureConfig.privateMode) {
            if (customerSet) storage.customerUserId = customerId
            storage.identityToken = if (storage.customerUserId == null) null else identityToken
        }
        if (l != null) storage.pendingLabel = l
        storage.identifyPending = true
        identifySeq++
        pump()
    }

    /** A label to send: trimmed, at most 80 characters ("" clears), and only where labels are allowed. */
    fun checkLabel(label: String?, call: String): String? {
        val l = label?.trim() ?: return null
        if (l.length > 80) {
            Log.e("$call: the label must be at most 80 characters; it was not sent")
            return null
        }
        if (!featureConfig.allowLabels) {
            if (!labelsWarned && deps.device.isDebuggableApp) {
                Log.w("Clikgate private mode is on and labels aren't allowed: the label was not sent.")
            }
            labelsWarned = true
            return null
        }
        return l
    }

    /** Private mode: a pending (unsent) identify loses its user id and token (and its label unless allowed). */
    private fun discardIdentify() {
        storage.customerUserId = null
        storage.identityToken = null
        if (!featureConfig.allowLabels) storage.pendingLabel = null
        storage.identifyPending = storage.pendingLabel != null
        identifySeq++
        warnPrivateMode()
        if (storage.identifyPending) return
        val ws = ArrayList(identifyWaiters)
        identifyWaiters.clear()
        ws.forEach { it() }
    }

    /** One warning per launch, debug builds only. */
    private fun warnPrivateMode() {
        if (privateModeWarned) return
        privateModeWarned = true
        if (deps.device.isDebuggableApp) {
            Log.w("Clikgate private mode is on: the customer ID of identifyUser(), event properties and event revenue are not sent. Use goal() for outcomes and values.")
        }
    }

    private fun sendIdentify() {
        identifyInFlight = true
        val seq = identifySeq
        val userId = storage.customerUserId
        val label = storage.pendingLabel
        val body = JSONObject()
        if (!featureConfig.privateMode) body.put("customer_user_id", userId ?: JSONObject.NULL)
        storage.identityToken?.let { body.put("identity_token", it) }
        label?.let { body.put("label", it) }
        body.put("consent", consentBody())
        val tokenSent = body.has("identity_token")
        send(ApiRequest("POST", "/v1/sdk/identify", body), maxAttempts = 5) { r ->
            identifyInFlight = false
            val done = when (r) {
                is ApiResult.Success -> {
                    if (r.body.optString("label_ignored") == "plan" && deps.device.isDebuggableApp) {
                        Log.w("identifyUser: labels need the Growth plan; the label was not stored")
                    }
                    // A bad token answers 200 with `verified: false` and a `reason`.
                    // Absent `verified` = an older server (which answers 422 identity_invalid instead).
                    if (tokenSent && r.body.has("verified") && !r.body.optBoolean("verified", true)) {
                        val reason = if (r.body.isNull("reason")) null else r.body.optString("reason").ifEmpty { null }
                        Log.w(identityTokenNotVerifiedMessage(reason))
                    }
                    true
                }
                is ApiResult.Failure -> {
                    if (r.error.code == "identity_invalid") {   // older servers
                        Log.w("identifyUser: the identity token did not verify (identity_invalid); the customer ID is kept but not verified")
                        true
                    } else if (r.retryable) {
                        identifyFailedSeq = seq // retried on next launch
                        false
                    } else {
                        Log.w("identifyUser failed: ${r.error.code}")
                        true
                    }
                }
            }
            if (done && seq == identifySeq) {
                storage.identifyPending = false
                if (storage.pendingLabel == label) storage.pendingLabel = null
            }
            if (seq == identifySeq) {
                val ws = ArrayList(identifyWaiters)
                identifyWaiters.clear()
                ws.forEach { it() }
            }
            pump()
        }
    }

    // ------------------------------------------------------------------ push

    fun setPushToken(token: String?, provider: PushProvider) = runSerial {
        if (token.isNullOrEmpty()) {
            storage.pushToken = null
            storage.pushProvider = null
            return@runSerial
        }
        storage.pushToken = token
        storage.pushProvider = provider.wireName
        pushFailedHash = null
        pump()
    }

    private fun currentPushJson(): JSONObject? {
        val token = storage.pushToken ?: return null
        val provider = storage.pushProvider ?: return null
        return JSONObject().put("provider", provider).put("token", token).put("apns_environment", JSONObject.NULL)
    }

    private fun maybeSendPushToken() {
        if (pushInFlight) return
        val push = currentPushJson() ?: return
        val h = hash(push.getString("provider") + push.getString("token"))
        if (h == storage.pushSentHash || h == pushFailedHash) return
        pushInFlight = true
        send(ApiRequest("POST", "/v1/sdk/push-token", JSONObject(push.toString()).put("consent", consentBody())), maxAttempts = 5) { r ->
            pushInFlight = false
            if (r is ApiResult.Success) storage.pushSentHash = h else pushFailedHash = h
            pump()
        }
    }

    // ------------------------------------------------------------------ opt-out

    fun setTrackingEnabled(enabled: Boolean) = runSerial {
        val was = storage.trackingEnabled
        storage.trackingEnabled = enabled
        if (!enabled) {
            queue.clear()
            refuseAllGoals("opted_out")
            pendingUrls.clear()
            openPending = null
        }
        if (storage.installDone) {
            if (was != enabled || storage.pendingOptOut != null) storage.pendingOptOut = !enabled
        }
        installStopped = false
        pump()
    }

    private fun sendOptOut(value: Boolean) {
        optOutInFlight = true
        send(ApiRequest("POST", "/v1/sdk/opt-out", JSONObject().put("opt_out", value)), maxAttempts = Int.MAX_VALUE) { r ->
            optOutInFlight = false
            if (r is ApiResult.Success && storage.pendingOptOut == value) storage.pendingOptOut = null
            pump()
        }
    }

    // ------------------------------------------------------------------ attestation refresh

    private fun maybeReattest() {
        if (attestInFlight || attestTried || !attestationEnabled()) return
        val interval = TimeUnit.DAYS.toMillis(config.reattestationIntervalDays.coerceAtLeast(1).toLong())
        if (deps.clock() - storage.lastAttestedAt < interval) return
        attestInFlight = true
        attestTried = true
        attest { att ->
            if (att == null) {
                attestInFlight = false
                return@attest
            }
            att.put("key_id", JSONObject.NULL)
            att.put("consent", consentBody())
            // Single attempt: the challenge is single use (a retry would be rejected anyway).
            send(ApiRequest("POST", "/v1/sdk/attest", att), maxAttempts = 1) { r ->
                attestInFlight = false
                if (r is ApiResult.Success) storage.lastAttestedAt = deps.clock()
            }
        }
    }

    // ------------------------------------------------------------------ referrals / v3 features

    /** A referral call (feature `referrals`, up to 3 attempts). [cb] runs on the main thread. */
    fun <T> referralCall(
        method: String,
        path: String,
        body: JSONObject?,
        parse: (JSONObject) -> T,
        cb: (ClikgateResult<T>) -> Unit,
    ) = featureCall("referrals", method, path, body, maxAttempts = 3, parse = parse, cb = cb)

    /**
     * Runs a call to an endpoint of [feature] once `/install` succeeded and a pending identify was
     * sent, adding the identity token header. Fails fast with `feature_disabled` (no network) when
     * the config says the feature is off, and maps the server's `feature_disabled` no-op body to
     * the same error (refreshing the config in the background). [cb] runs on the main thread.
     */
    fun <T> featureCall(
        feature: String,
        method: String,
        path: String,
        body: JSONObject?,
        maxAttempts: Int,
        maxRetryDelayMs: Long = Long.MAX_VALUE,
        parse: (JSONObject) -> T,
        cb: (ClikgateResult<T>) -> Unit,
    ) {
        fun finish(result: ClikgateResult<T>) {
            main.post { cb(result) }
        }
        fun disabled() = finish(ClikgateResult.Failure(featureDisabledError(feature)))
        if (!isFeatureEnabled(feature)) return disabled()
        runSerial {
            if (!storage.trackingEnabled) {
                finish(ClikgateResult.Failure(ClikgateError(ClikgateError.OPTED_OUT, "Tracking is disabled for this installation")))
                return@runSerial
            }
            changeGateError(if (feature == "offline_codes") "codes" else feature)?.let { return@runSerial finish(ClikgateResult.Failure(it)) }
            awaitInstall { ok ->
                if (!ok) {
                    finish(ClikgateResult.Failure(ClikgateError(ClikgateError.INSTALL_PENDING, "The install hasn't been recorded yet; try again shortly")))
                    return@awaitInstall
                }
                awaitIdentify {
                    // The config is loaded by now (first launch): check again before the request.
                    if (!isFeatureEnabled(feature)) return@awaitIdentify disabled()
                    val headers = storage.identityToken?.let { mapOf("Clikgate-Identity-Token" to it) } ?: emptyMap()
                    send(ApiRequest(method, path, body, headers), maxAttempts = maxAttempts, maxRetryDelayMs = maxRetryDelayMs) { r ->
                        when (r) {
                            is ApiResult.Success -> if (Json.isFeatureDisabled(r.body)) {
                                val key = r.body.str("feature") ?: feature
                                Log.i("The '$key' feature is switched off for this app (server answered feature_disabled)")
                                disabledByServer.add(key)
                                disabledByServer.add(feature)
                                refreshConfig()
                                finish(ClikgateResult.Failure(featureDisabledError(key)))
                            } else {
                                finish(
                                    try {
                                        ClikgateResult.Success(parse(r.body))
                                    } catch (e: Exception) {
                                        ClikgateResult.Failure(ClikgateError(ClikgateError.SERVER_ERROR, "Unexpected response: ${e.message}"))
                                    },
                                )
                            }
                            is ApiResult.Failure -> {
                                logIdentityRefusal(r.error.code, path)
                                finish(ClikgateResult.Failure(r.error))
                            }
                        }
                    }
                }
            }
        }
    }

    /**
     * A developer warning when a call is refused for the identity token
     * (`403 identity_expired`, `422 identity_invalid`). Never logs the token, the secret or the customer ID.
     */
    private fun logIdentityRefusal(code: String, path: String) {
        when (code) {
            "identity_expired" -> Log.w("$path: the identity token has expired (identity_expired); get a new token from your server and call identifyUser() again")
            "identity_invalid" -> Log.w("$path: the identity token did not verify (identity_invalid); get a new token from your server and call identifyUser() again")
        }
    }

    // ------------------------------------------------------------------ Engage request context

    /**
     * The request context for the Engage add-on / wrappers, once `/install` succeeded (waits up to
     * [Deps.installWaitForReferralMs], else `install_pending`) and a pending identify was sent, so
     * the server knows the user. Same gates as [featureCall]. [cb] runs on the main thread.
     */
    @OptIn(ClikgateInternalApi::class)
    fun requestContext(cb: (ClikgateResult<ClikgateRequestContext>) -> Unit) {
        fun finish(result: ClikgateResult<ClikgateRequestContext>) {
            main.post { cb(result) }
        }
        runSerial {
            val gate = when {
                !storage.trackingEnabled -> ClikgateError(ClikgateError.OPTED_OUT, "Tracking is disabled for this installation")
                invalidKey -> ClikgateError(ClikgateError.INVALID_SDK_KEY, "Invalid SDK key", 401)
                deps.clock() < disabledUntil -> ClikgateError(ClikgateError.SDK_DISABLED, "SDK disabled", 403)
                gate() != Gate.ALLOWED -> consentRequiredError()
                blocked && listOf("referrals", "leaderboards", "codes").none(::allows) ->
                    ClikgateError(ClikgateError.SDK_VERSION_BLOCKED, "This Clikgate SDK version is blocked; update the SDK.")
                else -> null
            }
            if (gate != null) return@runSerial finish(ClikgateResult.Failure(gate))
            awaitInstall { ok ->
                if (!ok) {
                    finish(ClikgateResult.Failure(ClikgateError(ClikgateError.INSTALL_PENDING, "The install hasn't been recorded yet; try again shortly")))
                    return@awaitInstall
                }
                awaitIdentify {
                    finish(
                        ClikgateResult.Success(
                            ClikgateRequestContext(
                                installationId = installationId,
                                sdkKey = sdkKey,
                                environment = options.environment.name.lowercase(Locale.US),
                                apiBaseUrl = options.apiBaseUrl.trimEnd('/'),
                                identityToken = storage.identityToken,
                                customerUserId = storage.customerUserId,
                                sdkVersion = if (wrapper != null) "${wrapper.name}/${wrapper.version}" else "android/$nativeVersion",
                                nativeSdkVersion = if (wrapper != null) "android/$nativeVersion" else null,
                            ),
                        ),
                    )
                }
            }
        }
    }

    /**
     * An error the Engage add-on got from a `/v1/sdk/...` call it made with the request context:
     * `feature_disabled` marks [feature] off until the next config fetch and refreshes the config in
     * the background (as [featureCall] does); `invalid_sdk_key`, `sdk_disabled` and
     * `installation_unknown` apply the global error rules. Other codes are ignored.
     */
    fun reportServerError(code: String, feature: String?) = runSerial {
        if (code == ClikgateError.FEATURE_DISABLED) {
            if (feature.isNullOrEmpty()) return@runSerial
            Log.i("The '$feature' feature is switched off for this app (server answered feature_disabled)")
            disabledByServer.add(feature)
            refreshConfig()
        } else {
            applyGlobalError(ClikgateError(code, code))
        }
    }

    private fun consentRequiredError() = ClikgateError(
        ClikgateError.CONSENT_REQUIRED,
        "Consent is required for this device and attribution isn't granted; nothing identifying is sent.",
    )

    /** Consent / version-policy restriction for an SDK call made for the app (null = allowed). */
    private fun changeGateError(call: String): ClikgateError? = when {
        !allows(call) -> ClikgateError(ClikgateError.SDK_VERSION_BLOCKED, "This Clikgate SDK version is blocked; update the SDK.")
        gate() != Gate.ALLOWED -> consentRequiredError()
        else -> null
    }

    private fun featureDisabledError(feature: String) = ClikgateError(
        ClikgateError.FEATURE_DISABLED,
        "The '$feature' feature is switched off for this app",
        feature = feature,
    )

    private fun awaitInstall(cb: (Boolean) -> Unit) {
        if (storage.installDone) return cb(true)
        val w = Waiter(cb)
        w.timeout = serial.schedule({
            installWaiters.remove(w)
            w.complete(storage.installDone)
        }, deps.installWaitForReferralMs, TimeUnit.MILLISECONDS)
        installWaiters.add(w)
        installStopped = false
        pump()
    }

    private fun awaitIdentify(cb: () -> Unit) {
        if (!storage.identifyPending || identifyFailedSeq == identifySeq) return cb()
        identifyWaiters.add(cb)
        pump()
    }

    // ------------------------------------------------------------------ test helpers

    internal fun isIdleForTests(): Boolean {
        val latch = CountDownLatch(1)
        var idle = false
        runSerial {
            idle = !installInFlight && !flushInFlight && !openInFlight && !pushInFlight &&
                !identifyInFlight && !optOutInFlight && !configInFlight
            latch.countDown()
        }
        latch.await(2, TimeUnit.SECONDS)
        return idle
    }

    companion object {
        private const val CONFIG_TTL_MS = 60 * 60 * 1000L
        private const val MAX_INSTALL_POLLS = 3
        private const val INSTALLATION_ID_WAIT_MS = 5_000L

        fun hash(s: String): String =
            MessageDigest.getInstance("SHA-256").digest(s.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }

        fun isoTimestamp(millis: Long): String =
            SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }.format(Date(millis))

        fun urlEncode(s: String): String = URLEncoder.encode(s, "UTF-8")

        /** The identify warning for `verified: false`; names the reason, never the token or customer ID. */
        fun identityTokenNotVerifiedMessage(reason: String?): String {
            val why = when (reason) {
                "expired" -> "expired"
                "bad_signature" -> "the signature doesn't match"
                "secret_rotated" -> "it was signed with a secret that has since been rotated"
                "no_secret_set" -> "no identity secret is set for this app"
                "not_yet_valid" -> "its issue time is in the future; check the server clock"
                null -> "no reason given"
                else -> reason.filter { it.isLetterOrDigit() || it == '_' }.take(40)   // a newer reason code
            }
            return "identifyUser: the identity token did not verify ($why); the customer ID is kept but not verified"
        }

        private fun namedThreads(prefix: String): ThreadFactory {
            val n = AtomicInteger()
            return ThreadFactory { r -> Thread(r, "$prefix-${n.incrementAndGet()}").apply { isDaemon = true } }
        }
    }
}
