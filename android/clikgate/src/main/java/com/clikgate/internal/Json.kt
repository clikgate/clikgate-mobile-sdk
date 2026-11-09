package com.clikgate.internal

import com.clikgate.ClikgateAttribution
import com.clikgate.ClikgateDeepLink
import com.clikgate.ClikgateLink
import com.clikgate.Referral
import com.clikgate.ReferredBy
import org.json.JSONArray
import org.json.JSONObject

/** org.json helpers and API (snake_case) -> model conversion. Unknown fields are ignored. */
internal object Json {

    fun JSONObject.str(key: String): String? =
        if (!has(key) || isNull(key)) null else opt(key)?.toString()

    fun JSONObject.obj(key: String): JSONObject? = if (isNull(key)) null else optJSONObject(key)

    fun JSONObject.bool(key: String, default: Boolean = false): Boolean =
        if (isNull(key)) default else optBoolean(key, default)

    fun JSONObject.long(key: String): Long? =
        if (isNull(key)) null else (opt(key) as? Number)?.toLong()

    fun JSONObject.int(key: String): Int = if (isNull(key)) 0 else optInt(key, 0)

    fun JSONObject.intOrNull(key: String): Int? =
        if (isNull(key)) null else (opt(key) as? Number)?.toInt()

    fun JSONObject.double(key: String): Double? =
        if (isNull(key)) null else (opt(key) as? Number)?.toDouble()

    fun toMap(o: JSONObject?): Map<String, Any?> {
        if (o == null) return emptyMap()
        val out = LinkedHashMap<String, Any?>()
        val keys = o.keys()
        while (keys.hasNext()) {
            val k = keys.next()
            out[k] = fromJson(o.opt(k))
        }
        return out
    }

    private fun toList(a: JSONArray): List<Any?> = (0 until a.length()).map { fromJson(a.opt(it)) }

    private fun fromJson(v: Any?): Any? = when (v) {
        null, JSONObject.NULL -> null
        is JSONObject -> toMap(v)
        is JSONArray -> toList(v)
        else -> v
    }

    /** Converts maps/lists/primitives to org.json values. Throws on unsupported types. */
    fun toJson(v: Any?): Any = when (v) {
        null -> JSONObject.NULL
        is String, is Boolean, is Int, is Long, is Double -> v
        is Float -> v.toDouble()
        is Short -> v.toInt()
        is Byte -> v.toInt()
        is Number -> v.toDouble()
        is Char -> v.toString()
        is Map<*, *> -> JSONObject().also { o ->
            for ((k, value) in v) {
                require(k is String) { "property keys must be strings" }
                o.put(k, toJson(value))
            }
        }
        is Iterable<*> -> JSONArray().also { a -> v.forEach { a.put(toJson(it)) } }
        is Array<*> -> JSONArray().also { a -> v.forEach { a.put(toJson(it)) } }
        is JSONObject, is JSONArray -> v
        else -> throw IllegalArgumentException("unsupported property type ${v.javaClass.name}")
    }

    fun link(o: JSONObject?): ClikgateLink? {
        if (o == null) return null
        val id = o.str("id") ?: return null
        return ClikgateLink(
            id = id,
            kind = o.str("kind") ?: "standard",
            externalReference = o.str("external_reference"),
            campaignId = o.str("campaign_id"),
            metadata = toMap(o.obj("metadata")),
        )
    }

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

    fun attribution(o: JSONObject?, installId: String?): ClikgateAttribution {
        if (o == null) return pendingAttribution(installId)
        return ClikgateAttribution(
            status = o.str("status") ?: ClikgateAttribution.STATUS_PENDING,
            matchType = o.str("match_type"),
            confidence = o.double("confidence"),
            clickId = o.str("click_id"),
            clickedAt = o.str("clicked_at"),
            isReinstall = o.bool("is_reinstall"),
            installId = installId,
            link = link(o.obj("link")),
        )
    }

    fun pendingAttribution(installId: String?): ClikgateAttribution = ClikgateAttribution(
        ClikgateAttribution.STATUS_PENDING, null, null, null, null, false, installId, null,
    )

    /** Deep link from an `/install` response (deep_link + attribution + referral). */
    fun installDeepLink(response: JSONObject): ClikgateDeepLink? {
        val dl = response.obj("deep_link") ?: return null
        val attribution = response.obj("attribution")
        return ClikgateDeepLink(
            url = dl.str("url"),
            path = dl.str("path"),
            data = toMap(dl.obj("data")),
            isDeferred = dl.bool("is_deferred", true),
            clickId = attribution?.str("click_id"),
            matchType = attribution?.str("match_type"),
            link = link(attribution?.obj("link")),
            referral = referral(response.obj("referral")),
        )
    }

    /** Deep link from a matched `/resolve` response. */
    fun resolveDeepLink(response: JSONObject, requestedUrl: String): ClikgateDeepLink {
        val dl = response.obj("deep_link")
        return ClikgateDeepLink(
            url = dl?.str("url") ?: requestedUrl,
            path = dl?.str("path"),
            data = toMap(dl?.obj("data")),
            isDeferred = dl?.bool("is_deferred", false) ?: false,
            clickId = response.str("click_id"),
            matchType = response.str("match_type") ?: "app_link",
            link = link(response.obj("link")),
            referral = referral(response.obj("referral")),
        )
    }

    /** A `/resolve` or `/install` answer for a gated link: `password_required` or `blocked`. */
    fun isGated(response: JSONObject): Boolean =
        response.str("status").let { it == "password_required" || it == "blocked" }

    /** A link blocked here: the message, the URL that opened the app, no path, click or link. */
    fun blockedDeepLink(url: String, message: String): ClikgateDeepLink =
        ClikgateDeepLink(url, null, emptyMap(), false, null, null, null, null, blockMessage = message)

    fun referredBy(o: JSONObject): ReferredBy {
        return ReferredBy(referred = o.bool("referred"), referral = referral(o.obj("referral")))
    }

    // ---------------------------------------------------------------- v3

    /** True for the `200 {"accepted": false, "reason": "feature_disabled"}` no-op body. */
    fun isFeatureDisabled(o: JSONObject): Boolean =
        o.str("reason") == "feature_disabled" && o.has("accepted") && !o.bool("accepted", true)
}
