package com.clikgate.reactnative

import android.app.Activity
import android.content.Intent
import com.clikgate.Attestation
import com.clikgate.Clikgate
import com.clikgate.ClikgateError
import com.clikgate.ClikgateInternalApi
import com.clikgate.ClikgateMoney
import com.clikgate.ClikgateOptions
import com.clikgate.ClikgateResult
import com.clikgate.ConsentState
import com.clikgate.Environment
import com.clikgate.FirebaseForwardingOptions
import com.clikgate.LogLevel
import com.clikgate.PushProvider
import com.facebook.react.bridge.ActivityEventListener
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.LifecycleEventListener
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.ReadableType

/**
 * TurboModule `Clikgate` over the Clikgate Android SDK. Contains no
 * attribution or referral logic: it converts arguments/results, forwards intents and emits deep
 * links as `ClikgateDeepLink` events.
 */
class ClikgateModule(reactContext: ReactApplicationContext) :
  NativeClikgateSpec(reactContext),
  ActivityEventListener,
  LifecycleEventListener {

  init {
    reactContext.addActivityEventListener(this)
    reactContext.addLifecycleEventListener(this)
    DeepLinkHub.attach(this)
    // Cold start: the intent that launched the activity (App Link / scheme). The SDK keeps it
    // until configure() is called from JS; each intent is handled only once.
    handleLaunchIntent(reactContext.currentActivity)
  }

  override fun getName(): String = NAME

  override fun invalidate() {
    reactApplicationContext.removeActivityEventListener(this)
    reactApplicationContext.removeLifecycleEventListener(this)
    DeepLinkHub.detach(this)
    super.invalidate()
  }

  // ------------------------------------------------------------------ intents

  private fun handleLaunchIntent(activity: Activity?) {
    val a = activity ?: return
    Clikgate.handleIntent(a, a.intent)
  }

  /** Warm start (singleTask / singleTop activity). */
  override fun onNewIntent(intent: Intent) {
    Clikgate.handleIntent(reactApplicationContext.currentActivity, intent)
  }

  override fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?) = Unit

  /** The module can be created after the activity; catch its launch intent on resume. */
  override fun onHostResume() = handleLaunchIntent(reactApplicationContext.currentActivity)

  override fun onHostPause() = Unit

  override fun onHostDestroy() = Unit

  // ------------------------------------------------------------------ events

  override fun addListener(eventName: String) {
    DeepLinkHub.addListener(this)
  }

  override fun removeListeners(count: Double) {
    DeepLinkHub.removeListeners(this, count.toInt())
  }

  internal fun emit(event: Map<String, Any?>): Boolean {
    val ctx = reactApplicationContext
    if (!ctx.hasActiveReactInstance()) return false
    ctx.emitDeviceEvent(EVENT_DEEP_LINK, BridgeMaps.toWritableMap(event))
    return true
  }

  // ------------------------------------------------------------------ methods

  @OptIn(ClikgateInternalApi::class)
  override fun configure(args: ReadableMap, promise: Promise) = guard(promise) {
    val sdkKey = args.string("sdkKey")
    if (sdkKey.isNullOrBlank()) return@guard invalid(promise, "sdkKey is required", "sdkKey")
    val options = ClikgateOptions(
      linkDomains = args.stringList("linkDomains"),
      logLevel = when (args.string("logLevel")) {
        "verbose" -> LogLevel.VERBOSE
        "debug" -> LogLevel.DEBUG
        "info" -> LogLevel.INFO
        "error" -> LogLevel.ERROR
        "none" -> LogLevel.NONE
        else -> LogLevel.WARN
      },
      environment = if (args.string("environment") == "sandbox") Environment.SANDBOX else Environment.PRODUCTION,
      attestation = if (args.string("attestation") == "ifAvailable") Attestation.PLAY_INTEGRITY_IF_AVAILABLE else Attestation.OFF,
      apiBaseUrl = args.string("apiBaseUrl")?.takeIf { it.isNotBlank() } ?: ClikgateOptions.DEFAULT_API_BASE_URL,
      deferredDeepLinkTimeoutMs = args.number("deferredDeepLinkTimeoutMs")?.toLong() ?: 5_000,
      platformDomainBrowserFallback = args.bool("platformDomainBrowserFallback", true),
    )
    // pasteboardMode / waitForATT are iOS-only and ignored here.
    if (!Clikgate.isConfigured) {
      Clikgate.setWrapper(WRAPPER_NAME, args.string("wrapperVersion") ?: "unknown")
      Clikgate.configure(reactApplicationContext.applicationContext, sdkKey, options)
    }
    // JS reloads re-run configure: the native SDK keeps running with the first configuration.
    handleLaunchIntent(reactApplicationContext.currentActivity)
    promise.resolve(null)
  }

  override fun getAttribution(args: ReadableMap, promise: Promise) = guard(promise) {
    Clikgate.attribution { promise.resolve(BridgeMaps.toWritableMap(BridgeMaps.attribution(it))) }
  }

  @OptIn(ClikgateInternalApi::class)
  override fun track(args: ReadableMap, promise: Promise) = guard(promise) {
    val name = args.string("name") ?: return@guard invalid(promise, "name is required", "name")
    val amount = args.number("revenueMinor")
    val currency = args.string("currency")
    if ((amount == null) != (currency == null)) {
      return@guard invalid(promise, "revenueMinor and currency go together", if (amount == null) "revenueMinor" else "currency")
    }
    if (amount != null && amount != Math.floor(amount)) {
      return@guard invalid(promise, "revenueMinor must be an integer", "revenueMinor")
    }
    val revenue = if (amount != null && currency != null) ClikgateMoney.ofMinor(amount.toLong(), currency) else null
    val properties = if (args.isType("properties", ReadableType.Map)) BridgeMaps.fromReadableMap(args.getMap("properties")) else null
    val error = Clikgate.trackValidated(name, revenue, properties)
    if (error != null) reject(promise, error) else promise.resolve(null)
  }

  /** The value arrives as a decimal string and becomes a BigDecimal natively; resolves with the goal's result. */
  @OptIn(ClikgateInternalApi::class)
  override fun goal(args: ReadableMap, promise: Promise) = guard(promise) {
    val key = args.string("key") ?: return@guard invalid(promise, "key is required", "goal")
    val isFirst = if (args.isType("isFirst", ReadableType.Boolean)) args.getBoolean("isFirst") else null
    Clikgate.goalFromWrapper(
      key, args.string("value"), args.string("currency"), args.string("reference"), args.string("provider"), isFirst,
      label = args.string("label"),
      onResult = { r ->
        promise.resolve(
          Arguments.createMap().apply {
            putString("status", r.status.value)
            putString("reason", r.reason)
            putString("goalKind", r.goalKind?.value)
            putBoolean("valueIgnored", r.valueIgnored)
          },
        )
      },
    )
  }

  /** `customerId` absent keeps the stored one; null clears it. */
  override fun identifyUser(args: ReadableMap, promise: Promise) = guard(promise) {
    val label = args.string("label")
    val token = args.string("identityToken")
    if (args.hasKey("customerId")) Clikgate.identifyUser(label, args.string("customerId"), token)
    else Clikgate.identifyUser(label = label, identityToken = token)
    promise.resolve(null)
  }

  override fun setTrackingEnabled(args: ReadableMap, promise: Promise) = guard(promise) {
    if (!args.isType("enabled", ReadableType.Boolean)) return@guard invalid(promise, "enabled is required", "enabled")
    Clikgate.setTrackingEnabled(args.getBoolean("enabled"))
    promise.resolve(null)
  }

  override fun setPushToken(args: ReadableMap, promise: Promise) = guard(promise) {
    val token = args.string("token")
    if (token.isNullOrEmpty()) return@guard invalid(promise, "token is required", "token")
    val provider = when (args.string("provider")) {
      "fcm" -> PushProvider.FCM
      "apns" -> PushProvider.APNS
      else -> return@guard invalid(promise, "provider must be fcm or apns", "provider")
    }
    Clikgate.setPushToken(token, provider)
    promise.resolve(null)
  }

  override fun handleUrl(args: ReadableMap, promise: Promise) = guard(promise) {
    val url = args.string("url") ?: return@guard invalid(promise, "url is required", "url")
    promise.resolve(Clikgate.handleUrl(url))
  }

  override fun referralsApplyCode(args: ReadableMap, promise: Promise) = guard(promise) {
    val programId = args.string("programId") ?: return@guard invalid(promise, "programId is required", "programId")
    val code = args.string("code") ?: return@guard invalid(promise, "code is required", "code")
    Clikgate.referrals.applyCode(programId, code) { reply(promise, it, FEATURE_REFERRALS, BridgeMaps::referral) }
  }

  override fun referralsReferredBy(args: ReadableMap, promise: Promise) = guard(promise) {
    Clikgate.referrals.referredBy { reply(promise, it, FEATURE_REFERRALS, BridgeMaps::referredBy) }
  }

  override fun sdkVersion(promise: Promise) {
    promise.resolve(Clikgate.sdkVersion)
  }

  // ------------------------------------------------------------------ v3 methods

  override fun isFeatureEnabled(args: ReadableMap, promise: Promise) = guard(promise) {
    val key = args.string("key")
    promise.resolve(!key.isNullOrEmpty() && Clikgate.isFeatureEnabled(key))
  }

  // ------------------------------------------------------------------ consent, Firebase, sales metadata

  override fun setConsent(args: ReadableMap, promise: Promise) = guard(promise) {
    val states = HashMap<String, ConsentState?>()
    for (key in CONSENT_KEYS) {
      if (!args.hasKey(key) || args.getType(key) == ReadableType.Null) {
        states[key] = null
        continue
      }
      val state = ConsentState.fromWire(args.string(key))
        ?: return@guard invalid(promise, "$key must be granted, denied or unknown", key)
      states[key] = state
    }
    Clikgate.setConsent(states["analytics"], states["attribution"], states["adUserData"], states["adPersonalization"])
    promise.resolve(null)
  }

  override fun getConsent(args: ReadableMap, promise: Promise) = guard(promise) {
    val c = Clikgate.getConsent()
    promise.resolve(
      BridgeMaps.toWritableMap(
        mapOf(
          "analytics" to c.analytics.wireName,
          "attribution" to c.attribution.wireName,
          "adUserData" to c.adUserData.wireName,
          "adPersonalization" to c.adPersonalization.wireName,
          "region" to c.region,
          "required" to c.required,
        ),
      ),
    )
  }

  override fun setConsentRegion(args: ReadableMap, promise: Promise) = guard(promise) {
    val region = args.string("region")?.trim()?.uppercase()
    if (region != null && !REGION.matches(region)) {
      return@guard invalid(promise, "region must be EEA, UK or an ISO 3166-1 alpha-2 country code", "region")
    }
    Clikgate.setConsentRegion(region)
    promise.resolve(null)
  }

  override fun enableFirebaseForwarding(args: ReadableMap, promise: Promise) = guard(promise) {
    val names = HashMap<String, String>()
    if (args.isType("eventNameMap", ReadableType.Map)) {
      BridgeMaps.fromReadableMap(args.getMap("eventNameMap"))?.forEach { (k, v) -> if (v is String) names[k] = v }
    }
    Clikgate.enableFirebaseForwarding(
      FirebaseForwardingOptions(
        logAttributionEvent = args.bool("logAttributionEvent", true),
        setUserProperties = args.bool("setUserProperties", true),
        mirrorEvents = args.bool("mirrorEvents", false),
        eventNameMap = names,
      ),
    )
    promise.resolve(null)
  }

  override fun attributionMetadata(args: ReadableMap, promise: Promise) = guard(promise) {
    promise.resolve(BridgeMaps.toWritableMap(Clikgate.attributionMetadata()))
  }

  /** Google on-device conversion measurement is iOS only. */
  override fun enableGoogleOnDeviceMeasurement(args: ReadableMap, promise: Promise) {
    promise.resolve(null)
  }

  // ------------------------------------------------------------------ Engage add-on (internal)

  /** Request context for `@clikgate/react-native-engage`. */
  @OptIn(ClikgateInternalApi::class)
  override fun getRequestContext(args: ReadableMap, promise: Promise) = guard(promise) {
    Clikgate.requestContext { r -> reply(promise, r, null, BridgeMaps::requestContext) }
  }

  @OptIn(ClikgateInternalApi::class)
  override fun reportServerError(args: ReadableMap, promise: Promise) = guard(promise) {
    val code = args.string("code")
    if (!code.isNullOrEmpty()) Clikgate.reportServerError(code, args.string("feature"))
    promise.resolve(null)
  }

  // ------------------------------------------------------------------ helpers

  private inline fun guard(promise: Promise, block: () -> Unit) {
    try {
      block()
    } catch (e: Exception) {
      promise.reject(ClikgateError.INVALID_ARGUMENT, e.message ?: e.javaClass.simpleName, BridgeMaps.errorInfo(null, null))
    }
  }

  /** Resolves a result map; `feature` names the feature of a `feature_disabled` failure. */
  private fun <T> reply(promise: Promise, r: ClikgateResult<T>, feature: String?, map: (T) -> Map<String, Any?>) {
    when (r) {
      is ClikgateResult.Success -> promise.resolve(BridgeMaps.toWritableMap(map(r.value)))
      is ClikgateResult.Failure -> reject(promise, r.error, feature)
    }
  }

  private fun reject(promise: Promise, error: ClikgateError, feature: String? = null) {
    // The SDK names the feature itself; the method's feature is the fallback
    val f = if (error.code == FEATURE_DISABLED) error.feature ?: feature else null
    promise.reject(
      error.code,
      error.message ?: error.code,
      BridgeMaps.errorInfo(error.status, error.param, f, error.offlineTouchId),
    )
  }

  private fun invalid(promise: Promise, message: String, param: String) {
    promise.reject(ClikgateError.INVALID_ARGUMENT, message, BridgeMaps.errorInfo(null, param))
  }

  private fun ReadableMap.isType(key: String, type: ReadableType): Boolean =
    hasKey(key) && getType(key) == type

  private fun ReadableMap.string(key: String): String? =
    if (isType(key, ReadableType.String)) getString(key) else null

  private fun ReadableMap.bool(key: String, default: Boolean): Boolean =
    if (isType(key, ReadableType.Boolean)) getBoolean(key) else default

  private fun ReadableMap.number(key: String): Double? =
    if (isType(key, ReadableType.Number)) getDouble(key) else null

  private fun ReadableMap.stringList(key: String): List<String> {
    if (!isType(key, ReadableType.Array)) return emptyList()
    val array = getArray(key) ?: return emptyList()
    return (0 until array.size()).mapNotNull { i ->
      if (array.getType(i) == ReadableType.String) array.getString(i) else null
    }
  }

  companion object {
    const val NAME = NativeClikgateSpec.NAME
    const val EVENT_DEEP_LINK = "ClikgateDeepLink"
    const val WRAPPER_NAME = "react-native"

    // v3 feature switches.
    const val FEATURE_DISABLED = "feature_disabled"
    const val FEATURE_REFERRALS = "referrals"

    // Consent, Firebase forwarding, sales metadata
    private val CONSENT_KEYS = listOf("analytics", "attribution", "adUserData", "adPersonalization")
    private val REGION = Regex("^(EEA|UK|[A-Z]{2})$")
  }
}
