package com.clikgate.clikgate_flutter

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import com.clikgate.Attestation
import com.clikgate.Clikgate
import com.clikgate.ClikgateAttribution
import com.clikgate.ClikgateConsent
import com.clikgate.ClikgateDeepLink
import com.clikgate.ClikgateError
import com.clikgate.ClikgateInternalApi
import com.clikgate.ClikgateLink
import com.clikgate.ClikgateMoney
import com.clikgate.ClikgateOptions
import com.clikgate.ClikgateRequestContext
import com.clikgate.ClikgateResult
import com.clikgate.ConsentState
import com.clikgate.Environment
import com.clikgate.FirebaseForwardingOptions
import com.clikgate.LogLevel
import com.clikgate.PushProvider
import com.clikgate.Referral
import com.clikgate.ReferredBy
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Flutter bridge over the Clikgate Android SDK. Contains no
 * attribution or referral logic: it converts arguments/results and forwards intents.
 */
class ClikgateFlutterPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.NewIntentListener,
    EventChannel.StreamHandler {

    private var context: Context? = null
    private var methods: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var events: EventChannel? = null
    private var activityBinding: ActivityPluginBinding? = null

    // ------------------------------------------------------------------ FlutterPlugin

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).also { it.setStreamHandler(this) }
        DeepLinkHub.install()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        DeepLinkHub.removeSink(this)
        methods = null
        events = null
        context = null
    }

    // ------------------------------------------------------------------ EventChannel

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        DeepLinkHub.addSink(this, events)
    }

    override fun onCancel(arguments: Any?) {
        DeepLinkHub.removeSink(this)
    }

    // ------------------------------------------------------------------ ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(this)
        // Cold start: the intent that launched the activity (App Link / scheme). The SDK keeps
        // it until configure() is called from Dart; each intent is handled only once.
        Clikgate.handleIntent(binding.activity, binding.activity.intent)
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(this)
    }

    override fun onDetachedFromActivity() = detachActivity()

    private fun detachActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }

    /** Warm start (singleTop / singleTask activity). Never consumes the intent. */
    override fun onNewIntent(intent: Intent): Boolean {
        val activity: Activity? = activityBinding?.activity
        Clikgate.handleIntent(activity, intent)
        return false
    }

    // ------------------------------------------------------------------ methods

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "configure" -> configure(call, result)
                "getAttribution" -> Clikgate.attribution { result.success(attributionMap(it)) }
                "track" -> track(call, result)
                "goal" -> goal(call, result)
                "identifyUser" -> {
                    val label = call.argument<String>("label")
                    val token = call.argument<String>("identityToken")
                    if (call.hasArgument("customerId")) {
                        Clikgate.identifyUser(label, call.argument<String>("customerId"), token)
                    } else {
                        Clikgate.identifyUser(label = label, identityToken = token)
                    }
                    result.success(null)
                }
                "setTrackingEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: return invalid(result, "enabled is required", "enabled")
                    Clikgate.setTrackingEnabled(enabled)
                    result.success(null)
                }
                "setPushToken" -> {
                    val token = call.argument<String>("token") ?: return invalid(result, "token is required", "token")
                    val provider = when (call.argument<String>("provider")) {
                        "fcm" -> PushProvider.FCM
                        "apns" -> PushProvider.APNS
                        else -> return invalid(result, "provider must be fcm or apns", "provider")
                    }
                    Clikgate.setPushToken(token, provider)
                    result.success(null)
                }
                "handleUrl" -> {
                    val url = call.argument<String>("url") ?: return invalid(result, "url is required", "url")
                    result.success(Clikgate.handleUrl(url))
                }
                "referrals.applyCode" -> {
                    val programId = call.argument<String>("programId") ?: return invalid(result, "programId is required", "programId")
                    val code = call.argument<String>("code") ?: return invalid(result, "code is required", "code")
                    Clikgate.referrals.applyCode(programId, code) { reply(result, it, ::referralMap) }
                }
                "referrals.referredBy" -> Clikgate.referrals.referredBy { reply(result, it, ::referredByMap) }
                // ---- v3
                "isFeatureEnabled" -> {
                    val key = call.argument<String>("key") ?: return invalid(result, "key is required", "key")
                    result.success(Clikgate.isFeatureEnabled(key))
                }
                // ---- consent, Firebase, sales metadata
                "setConsent" -> setConsent(call, result)
                "getConsent" -> result.success(consentMap(Clikgate.getConsent()))
                "setConsentRegion" -> {
                    val region = call.argument<String>("region")
                    if (region != null && !REGION.matches(region.trim().uppercase())) {
                        return invalid(result, "region must be EEA, UK or an ISO 3166-1 alpha-2 country code", "region")
                    }
                    Clikgate.setConsentRegion(region)
                    result.success(null)
                }
                "enableFirebaseForwarding" -> {
                    @Suppress("UNCHECKED_CAST")
                    val map = (call.argument<Map<String, Any?>>("eventNameMap") ?: emptyMap())
                        .mapNotNull { (k, v) -> (v as? String)?.let { k to it } }.toMap()
                    Clikgate.enableFirebaseForwarding(
                        FirebaseForwardingOptions(
                            logAttributionEvent = call.argument<Boolean>("logAttributionEvent") ?: true,
                            setUserProperties = call.argument<Boolean>("setUserProperties") ?: true,
                            mirrorEvents = call.argument<Boolean>("mirrorEvents") ?: false,
                            eventNameMap = map,
                        ),
                    )
                    result.success(null)
                }
                "attributionMetadata" -> result.success(Clikgate.attributionMetadata())
                // iOS only (Google on-device conversion measurement).
                "enableGoogleOnDeviceMeasurement" -> result.success(null)
                // ---- Engage add-on support (internal): clikgate_engage calls /v1/sdk/... itself
                "getRequestContext" -> requestContext(result)
                "reportServerError" -> reportServerError(call, result)
                "sdkVersion" -> result.success(Clikgate.sdkVersion)
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error(ClikgateError.INVALID_ARGUMENT, e.message ?: e.javaClass.simpleName, details(null, null))
        }
    }

    @OptIn(ClikgateInternalApi::class)
    private fun configure(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: return result.error(ClikgateError.NOT_CONFIGURED, "Plugin not attached", details(null, null))
        val sdkKey = call.argument<String>("sdkKey")
        if (sdkKey.isNullOrBlank()) return invalid(result, "sdkKey is required", "sdkKey")
        val options = ClikgateOptions(
            linkDomains = call.argument<List<String>>("linkDomains") ?: emptyList(),
            logLevel = when (call.argument<String>("logLevel")) {
                "verbose" -> LogLevel.VERBOSE
                "debug" -> LogLevel.DEBUG
                "info" -> LogLevel.INFO
                "error" -> LogLevel.ERROR
                "none" -> LogLevel.NONE
                else -> LogLevel.WARN
            },
            environment = if (call.argument<String>("environment") == "sandbox") Environment.SANDBOX else Environment.PRODUCTION,
            attestation = if (call.argument<String>("attestation") == "ifAvailable") Attestation.PLAY_INTEGRITY_IF_AVAILABLE else Attestation.OFF,
            apiBaseUrl = call.argument<String>("apiBaseUrl")?.takeIf { it.isNotBlank() } ?: ClikgateOptions.DEFAULT_API_BASE_URL,
            deferredDeepLinkTimeoutMs = (call.argument<Any>("deferredDeepLinkTimeoutMs") as? Number)?.toLong() ?: 5_000,
            platformDomainBrowserFallback = call.argument<Boolean>("platformDomainBrowserFallback") ?: true,
        )
        // pasteboardMode / waitForATT are iOS-only and ignored here.
        Clikgate.setWrapper("flutter", call.argument<String>("wrapperVersion") ?: "unknown")
        Clikgate.configure(ctx, sdkKey, options)
        result.success(null)
    }

    @OptIn(ClikgateInternalApi::class)
    private fun track(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("name") ?: return invalid(result, "name is required", "name")
        val amount = (call.argument<Any>("revenueMinor") as? Number)?.toLong()
        val currency = call.argument<String>("currency")
        if ((amount == null) != (currency == null)) {
            return invalid(result, "revenueMinor and currency go together", if (amount == null) "revenueMinor" else "currency")
        }
        val revenue = if (amount != null && currency != null) ClikgateMoney.ofMinor(amount, currency) else null
        val properties = call.argument<Map<String, Any?>>("properties")
        val error = Clikgate.trackValidated(name, revenue, properties)
        if (error != null) result.error(error.code, error.message, details(error.status, error.param)) else result.success(null)
    }

    /** The value arrives as a decimal string and becomes a BigDecimal natively; answers with the goal's result. */
    @OptIn(ClikgateInternalApi::class)
    private fun goal(call: MethodCall, result: MethodChannel.Result) {
        val key = call.argument<String>("key") ?: return invalid(result, "key is required", "goal")
        Clikgate.goalFromWrapper(
            key, call.argument<String>("value"), call.argument<String>("currency"),
            call.argument<String>("reference"), call.argument<String>("provider"), call.argument<Boolean>("isFirst"),
            onResult = { r ->
                val map = mapOf(
                    "status" to r.status.value, "reason" to r.reason,
                    "goalKind" to r.goalKind?.value, "valueIgnored" to r.valueIgnored,
                )
                mainHandler.post { result.success(map) }
            },
            label = call.argument<String>("label"),
        )
    }

    private fun setConsent(call: MethodCall, result: MethodChannel.Result) {
        val states = arrayOfNulls<ConsentState>(4)
        for ((i, key) in listOf("analytics", "attribution", "adUserData", "adPersonalization").withIndex()) {
            val raw = call.argument<String>(key) ?: continue
            states[i] = ConsentState.fromWire(raw) ?: return invalid(result, "$key must be granted, denied or unknown", key)
        }
        Clikgate.setConsent(states[0], states[1], states[2], states[3])
        result.success(null)
    }

    @OptIn(ClikgateInternalApi::class)
    private fun requestContext(result: MethodChannel.Result) {
        Clikgate.requestContext { reply(result, it, ::requestContextMap) }
    }

    @OptIn(ClikgateInternalApi::class)
    private fun reportServerError(call: MethodCall, result: MethodChannel.Result) {
        val code = call.argument<String>("code") ?: return invalid(result, "code is required", "code")
        Clikgate.reportServerError(code, call.argument<String>("feature"))
        result.success(null)
    }

    private fun <T> reply(result: MethodChannel.Result, r: ClikgateResult<T>, map: (T) -> Any?) {
        when (r) {
            is ClikgateResult.Success -> result.success(map(r.value))
            is ClikgateResult.Failure -> result.error(r.error.code, r.error.message ?: r.error.code, errorDetails(r.error))
        }
    }

    /** `{status, param}` plus `feature` (feature_disabled) and `offlineTouchId` (codes.redeem) when set. */
    private fun errorDetails(e: ClikgateError): Map<String, Any?> {
        val d = LinkedHashMap(details(e.status, e.param))
        e.feature?.let { d["feature"] = it }
        e.offlineTouchId?.let { d["offlineTouchId"] = it }
        return d
    }

    private fun invalid(result: MethodChannel.Result, message: String, param: String) =
        result.error(ClikgateError.INVALID_ARGUMENT, message, details(null, param))

    private fun details(status: Int?, param: String?): Map<String, Any?> = mapOf("status" to status, "param" to param)

    // ------------------------------------------------------------------ deep link fan-out

    /**
     * One SDK listener shared by all engines (e.g. the UI engine and a background-messaging
     * engine). Links that arrive while no Dart side listens are buffered (latest 10) and
     * flushed on the next `onListen`. The SDK calls back on the main thread, where sinks must
     * be used.
     */
    private object DeepLinkHub {
        private val sinks = LinkedHashMap<ClikgateFlutterPlugin, EventChannel.EventSink>()
        private val buffer = ArrayDeque<Map<String, Any?>>()
        private var installed = false

        @Synchronized
        fun install() {
            if (installed) return
            installed = true
            Clikgate.onDeepLink { link -> dispatch(deepLinkMap(link)) }
            // Browser handoffs share the event channel, tagged.
            Clikgate.onBrowserHandoff { h -> dispatch(mapOf("event" to "browserHandoff", "url" to h.url, "host" to h.host)) }
        }

        @Synchronized
        fun addSink(owner: ClikgateFlutterPlugin, sink: EventChannel.EventSink) {
            sinks[owner] = sink
            while (buffer.isNotEmpty()) sink.success(buffer.removeFirst())
        }

        @Synchronized
        fun removeSink(owner: ClikgateFlutterPlugin) {
            sinks.remove(owner)
        }

        @Synchronized
        private fun dispatch(event: Map<String, Any?>) {
            if (sinks.isEmpty()) {
                buffer.addLast(event)
                while (buffer.size > 10) buffer.removeFirst()
                return
            }
            sinks.values.forEach { it.success(event) }
        }
    }

    companion object {
        const val METHOD_CHANNEL = "com.clikgate/sdk"
        const val EVENT_CHANNEL = "com.clikgate/deep_links"
        private val REGION = Regex("^(EEA|UK|[A-Z]{2})$")

        fun consentMap(c: ClikgateConsent): Map<String, Any?> = mapOf(
            "analytics" to c.analytics.wireName,
            "attribution" to c.attribution.wireName,
            "adUserData" to c.adUserData.wireName,
            "adPersonalization" to c.adPersonalization.wireName,
            "region" to c.region,
            "required" to c.required,
        )

        // App-defined maps (data, metadata) are passed through verbatim (no key conversion).

        fun linkMap(l: ClikgateLink?): Map<String, Any?>? = l?.let {
            mapOf(
                "id" to it.id,
                "kind" to it.kind,
                "externalReference" to it.externalReference,
                "campaignId" to it.campaignId,
                "metadata" to it.metadata,
            )
        }

        fun referralMap(r: Referral): Map<String, Any?> = mapOf(
            "referralId" to r.referralId,
            "programId" to r.programId,
            "status" to r.status,
            "source" to r.source,
            "referrerId" to r.referrerId,
            "referrerDisplayName" to r.referrerDisplayName,
            "createdAt" to r.createdAt,
        )

        fun deepLinkMap(d: ClikgateDeepLink): Map<String, Any?> = mapOf(
            "url" to d.url,
            "path" to d.path,
            "data" to d.data,
            "isDeferred" to d.isDeferred,
            "clickId" to d.clickId,
            "matchType" to d.matchType,
            "link" to linkMap(d.link),
            "referral" to d.referral?.let(::referralMap),
            "blockMessage" to d.blockMessage,
        )

        fun attributionMap(a: ClikgateAttribution): Map<String, Any?> = mapOf(
            "status" to a.status,
            "matchType" to a.matchType,
            "confidence" to a.confidence,
            "clickId" to a.clickId,
            "clickedAt" to a.clickedAt,
            "isReinstall" to a.isReinstall,
            "installId" to a.installId,
            "link" to linkMap(a.link),
        )

        fun referredByMap(r: ReferredBy): Map<String, Any?> = mapOf(
            "referred" to r.referred,
            "referral" to r.referral?.let(::referralMap),
        )

        @OptIn(ClikgateInternalApi::class)
        fun requestContextMap(c: ClikgateRequestContext): Map<String, Any?> = mapOf(
            "installationId" to c.installationId,
            "sdkKey" to c.sdkKey,
            "environment" to c.environment,
            "apiBaseUrl" to c.apiBaseUrl,
            "identityToken" to c.identityToken,
            "customerUserId" to c.customerUserId,
            "sdkVersion" to c.sdkVersion,
            "nativeSdkVersion" to c.nativeSdkVersion,
        )
    }
}
