package com.clikgate.reactnative

import com.clikgate.ClikgateAttribution
import com.clikgate.ClikgateDeepLink
import com.clikgate.ClikgateInternalApi
import com.clikgate.ClikgateLink
import com.clikgate.ClikgateRequestContext
import com.clikgate.Referral
import com.clikgate.ReferredBy
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.ReadableType
import com.facebook.react.bridge.WritableArray
import com.facebook.react.bridge.WritableMap
import org.json.JSONArray
import org.json.JSONObject

/**
 * Bridge result maps (camelCase keys, JSON values) and conversions
 * between them and React Native's Readable/Writable types. App-defined maps (`data`,
 * `metadata`, `properties`) pass through verbatim (no key conversion).
 */
internal object BridgeMaps {

  fun link(l: ClikgateLink?): Map<String, Any?>? = l?.let {
    mapOf(
      "id" to it.id,
      "kind" to it.kind,
      "externalReference" to it.externalReference,
      "campaignId" to it.campaignId,
      "metadata" to it.metadata,
    )
  }

  fun referral(r: Referral): Map<String, Any?> = mapOf(
    "referralId" to r.referralId,
    "programId" to r.programId,
    "status" to r.status,
    "source" to r.source,
    "referrerId" to r.referrerId,
    "referrerDisplayName" to r.referrerDisplayName,
    "createdAt" to r.createdAt,
  )

  fun deepLink(d: ClikgateDeepLink): Map<String, Any?> = mapOf(
    "url" to d.url,
    "path" to d.path,
    "data" to d.data,
    "isDeferred" to d.isDeferred,
    "clickId" to d.clickId,
    "matchType" to d.matchType,
    "link" to link(d.link),
    "referral" to d.referral?.let(::referral),
    "blockMessage" to d.blockMessage,
  )

  fun attribution(a: ClikgateAttribution): Map<String, Any?> = mapOf(
    "status" to a.status,
    "matchType" to a.matchType,
    "confidence" to a.confidence,
    "clickId" to a.clickId,
    "clickedAt" to a.clickedAt,
    "isReinstall" to a.isReinstall,
    "installId" to a.installId,
    "link" to link(a.link),
  )

  fun referredBy(r: ReferredBy): Map<String, Any?> = mapOf(
    "referred" to r.referred,
    "referral" to r.referral?.let(::referral),
  )

  /** Engage add-on request context. */
  @OptIn(ClikgateInternalApi::class)
  fun requestContext(c: ClikgateRequestContext): Map<String, Any?> = mapOf(
    "installationId" to c.installationId,
    "sdkKey" to c.sdkKey,
    "environment" to c.environment,
    "apiBaseUrl" to c.apiBaseUrl,
    "identityToken" to c.identityToken,
    "customerUserId" to c.customerUserId,
    "sdkVersion" to c.sdkVersion,
    "nativeSdkVersion" to c.nativeSdkVersion,
  )

  /** `userInfo` of a promise rejection: `{status, param}`, plus `feature` / `offlineTouchId` when set. */
  fun errorInfo(
    status: Int?,
    param: String?,
    feature: String? = null,
    offlineTouchId: String? = null,
  ): WritableMap = Arguments.createMap().apply {
    if (status != null) putInt("status", status) else putNull("status")
    if (param != null) putString("param", param) else putNull("param")
    if (feature != null) putString("feature", feature)
    if (offlineTouchId != null) putString("offlineTouchId", offlineTouchId)
  }

  // ------------------------------------------------------------------ Kotlin -> JS

  fun toWritableMap(map: Map<*, *>): WritableMap {
    val out = Arguments.createMap()
    for ((k, v) in map) putValue(out, k.toString(), v)
    return out
  }

  private fun toWritableArray(items: Iterable<*>): WritableArray {
    val out = Arguments.createArray()
    for (v in items) pushValue(out, v)
    return out
  }

  private fun putValue(out: WritableMap, key: String, v: Any?) {
    when (v) {
      null, JSONObject.NULL -> out.putNull(key)
      is Boolean -> out.putBoolean(key, v)
      is Int -> out.putInt(key, v)
      is Number -> out.putDouble(key, v.toDouble())
      is String -> out.putString(key, v)
      is Map<*, *> -> out.putMap(key, toWritableMap(v))
      is JSONObject -> out.putMap(key, toWritableMap(jsonObjectToMap(v)))
      is JSONArray -> out.putArray(key, toWritableArray(jsonArrayToList(v)))
      is Iterable<*> -> out.putArray(key, toWritableArray(v))
      is Array<*> -> out.putArray(key, toWritableArray(v.asList()))
      else -> out.putString(key, v.toString())
    }
  }

  private fun pushValue(out: WritableArray, v: Any?) {
    when (v) {
      null, JSONObject.NULL -> out.pushNull()
      is Boolean -> out.pushBoolean(v)
      is Int -> out.pushInt(v)
      is Number -> out.pushDouble(v.toDouble())
      is String -> out.pushString(v)
      is Map<*, *> -> out.pushMap(toWritableMap(v))
      is JSONObject -> out.pushMap(toWritableMap(jsonObjectToMap(v)))
      is JSONArray -> out.pushArray(toWritableArray(jsonArrayToList(v)))
      is Iterable<*> -> out.pushArray(toWritableArray(v))
      is Array<*> -> out.pushArray(toWritableArray(v.asList()))
      else -> out.pushString(v.toString())
    }
  }

  private fun jsonObjectToMap(o: JSONObject): Map<String, Any?> =
    o.keys().asSequence().associateWith { o.opt(it) }

  private fun jsonArrayToList(a: JSONArray): List<Any?> = (0 until a.length()).map { a.opt(it) }

  // ------------------------------------------------------------------ JS -> Kotlin

  /**
   * JS numbers arrive as doubles; whole numbers are passed on as Long so event properties keep
   * their integer JSON form (`3`, not `3.0`).
   */
  fun fromReadableMap(map: ReadableMap?): Map<String, Any?>? {
    if (map == null) return null
    val out = LinkedHashMap<String, Any?>()
    val it = map.keySetIterator()
    while (it.hasNextKey()) {
      val key = it.nextKey()
      out[key] = when (map.getType(key)) {
        ReadableType.Null -> null
        ReadableType.Boolean -> map.getBoolean(key)
        ReadableType.Number -> number(map.getDouble(key))
        ReadableType.String -> map.getString(key)
        ReadableType.Map -> fromReadableMap(map.getMap(key))
        ReadableType.Array -> fromReadableArray(map.getArray(key))
      }
    }
    return out
  }

  private fun fromReadableArray(array: ReadableArray?): List<Any?>? {
    if (array == null) return null
    return (0 until array.size()).map { i ->
      when (array.getType(i)) {
        ReadableType.Null -> null
        ReadableType.Boolean -> array.getBoolean(i)
        ReadableType.Number -> number(array.getDouble(i))
        ReadableType.String -> array.getString(i)
        ReadableType.Map -> fromReadableMap(array.getMap(i))
        ReadableType.Array -> fromReadableArray(array.getArray(i))
      }
    }
  }

  private fun number(d: Double): Any =
    if (d == Math.floor(d) && !d.isInfinite() && Math.abs(d) < 9.007199254740992E15) d.toLong() else d
}
