package com.clikgate.reactnative.engage

import com.clikgate.ClikgateError
import com.clikgate.engage.ClikgateEngage
import com.clikgate.engage.ReferralLink
import com.clikgate.engage.ShareApp
import com.clikgate.reactnative.NativeClikgateEngageSpec
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.UiThreadUtil

/**
 * TurboModule `ClikgateEngage`: `shareLink` over the native SDK's Engage features
 * (com.clikgate.engage in com.clikgate:clikgate-android), which give each app its own version of the
 * link and record the share. Everything else in the Engage features (src/engage) is TypeScript.
 * Registered by ClikgatePackage (one package since 2.1.0).
 */
class ClikgateEngageModule(reactContext: ReactApplicationContext) : NativeClikgateEngageSpec(reactContext) {
  override fun getName(): String = NAME

  override fun shareLink(args: ReadableMap, promise: Promise) {
    val url = if (args.hasKey("url")) args.getString("url") else null
    if (url.isNullOrBlank()) return promise.reject(ClikgateError.INVALID_ARGUMENT, "url is required")
    fun str(key: String) = if (args.hasKey(key) && !args.isNull(key)) args.getString(key) else null
    val app = str("app")?.let { v -> ShareApp.entries.firstOrNull { it.value == v } }
    val given = HashMap<ShareApp, String>()
    if (args.hasKey("shareUrls") && !args.isNull("shareUrls")) {
      val map = args.getMap("shareUrls")!!.toHashMap()
      for ((k, v) in map) {
        val a = ShareApp.entries.firstOrNull { it.value == k }
        if (a != null && v is String) given[a] = v
      }
    }
    UiThreadUtil.runOnUiThread {
      val ctx = reactApplicationContext.currentActivity ?: reactApplicationContext
      try {
        val code = str("code")
        val opened = if (code != null) {
          ClikgateEngage.share.referralLink(ctx, ReferralLink("", "", code, url, str("shortUrl") ?: ""), str("message"), app)
        } else {
          ClikgateEngage.share.link(ctx, url, str("message"), app, given.ifEmpty { null })
        }
        promise.resolve(opened)
      } catch (e: ClikgateError) {
        promise.reject(e.code, e.message ?: e.code)
      }
    }
  }

  companion object {
    const val NAME = "ClikgateEngage"
  }
}
