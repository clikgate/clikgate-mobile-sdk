package com.clikgate.internal

import android.net.Uri
import com.clikgate.ConsentState
import org.json.JSONObject
import java.net.URLDecoder

/** Consent purposes stored on the device */
internal data class ConsentValues(
    val analytics: ConsentState = ConsentState.UNKNOWN,
    val attribution: ConsentState = ConsentState.UNKNOWN,
    val adUserData: ConsentState = ConsentState.UNKNOWN,
    val adPersonalization: ConsentState = ConsentState.UNKNOWN,
    /** ISO 8601 time of the last `setConsent`, null = never. */
    val updatedAt: String? = null,
    val region: String? = null,
) {
    fun json(): JSONObject = JSONObject()
        .put("analytics", analytics.wireName)
        .put("attribution", attribution.wireName)
        .put("ad_user_data", adUserData.wireName)
        .put("ad_personalization", adPersonalization.wireName)
        .put("region", region ?: JSONObject.NULL)
        .put("updated_at", updatedAt ?: JSONObject.NULL)

    companion object {
        fun parse(text: String?): ConsentValues {
            if (text == null) return ConsentValues()
            return try {
                val o = JSONObject(text)
                fun st(k: String) = ConsentState.fromWire(o.optString(k)) ?: ConsentState.UNKNOWN
                ConsentValues(
                    st("analytics"), st("attribution"), st("ad_user_data"), st("ad_personalization"),
                    if (o.isNull("updated_at")) null else o.optString("updated_at").ifEmpty { null },
                    if (o.isNull("region")) null else o.optString("region").ifEmpty { null },
                )
            } catch (_: Exception) {
                ConsentValues()
            }
        }
    }
}

/** `/config` `consent` object. */
internal data class ConsentConfig(
    val mode: String,
    val required: Boolean,
    val requiredRegions: List<String>,
    val anonymousCounts: Boolean,
    val bufferMaxDays: Int,
    val bufferMaxEvents: Int,
    val identityChecksBasis: String,
) {
    companion object {
        fun parse(o: JSONObject?): ConsentConfig? {
            if (o == null) return null
            val regions = o.optJSONArray("required_regions")?.let { a ->
                (0 until a.length()).mapNotNull { (a.opt(it) as? String)?.uppercase() }
            } ?: Consent.DEFAULT_REGIONS
            return ConsentConfig(
                mode = o.optString("mode", "not_required"),
                required = o.optBoolean("required", false),
                requiredRegions = regions,
                anonymousCounts = o.optBoolean("anonymous_counts", false),
                bufferMaxDays = o.optInt("buffer_max_days", 7).coerceIn(1, 7),
                bufferMaxEvents = o.optInt("buffer_max_events", 1000).coerceIn(1, 1000),
                identityChecksBasis = o.optString("identity_checks_basis", "consent"),
            )
        }
    }
}

/** What the consent gate allows right now. */
internal enum class Gate { ALLOWED, PENDING, DENIED }

internal object Consent {
    val DEFAULT_REGIONS = listOf("EEA", "UK", "CH")

    /** EU 27 + Iceland, Liechtenstein, Norway. */
    val EEA = setOf(
        "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE", "IT", "LV", "LT",
        "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE", "IS", "LI", "NO",
    )

    private val REGION = Regex("^(EEA|UK|[A-Z]{2})$")

    /** Normalised region hint, or null when invalid. */
    fun normalizeRegion(region: String): String? = region.trim().uppercase().takeIf { REGION.matches(it) }

    fun regionMatches(hint: String, regions: List<String>): Boolean = regions.any { r ->
        val region = r.uppercase()
        region == hint || (region == "EEA" && hint in EEA) || (region == "UK" && hint == "GB") || (region == "GB" && hint == "UK")
    }

    /** Is consent required? Null when unknown (no config, no hint). */
    fun required(config: ConsentConfig?, hint: String?): Boolean? {
        if (config == null) return if (hint != null) regionMatches(hint, DEFAULT_REGIONS) else null
        return when (config.mode) {
            "not_required" -> false
            "required_everywhere" -> true
            else -> if (hint != null) regionMatches(hint, config.requiredRegions) else config.required
        }
    }

    fun allowed(state: ConsentState, required: Boolean): Boolean =
        state == ConsentState.GRANTED || (!required && state != ConsentState.DENIED)

    fun gate(values: ConsentValues, required: Boolean): Gate = when {
        !required -> Gate.ALLOWED
        values.attribution == ConsentState.GRANTED -> Gate.ALLOWED
        values.attribution == ConsentState.DENIED -> Gate.DENIED
        else -> Gate.PENDING
    }
}

/** Google click ids. */
internal object ClickIds {
    private val KEYS = listOf("gclid", "gbraid", "wbraid")
    private const val MAX = 512

    private fun clean(v: String?): String? = v?.trim()?.takeIf { it.isNotEmpty() && it.length <= MAX }

    /** From a URL's query (app links, custom scheme). Null when it carries none. */
    fun fromUrl(url: String?): JSONObject? {
        if (url == null) return null
        val uri = try {
            Uri.parse(url)
        } catch (_: Exception) {
            return null
        }
        if (!uri.isHierarchical) return null
        val values = KEYS.associateWith { k ->
            try {
                clean(uri.getQueryParameter(k))
            } catch (_: Exception) {
                null
            }
        }
        return build(values, "deep_link")
    }

    /** From the raw Play install referrer string (URL-decoded once, `&`-separated). */
    fun fromReferrer(referrer: String?): JSONObject? {
        if (referrer.isNullOrEmpty()) return null
        val decoded = try {
            URLDecoder.decode(referrer, "UTF-8")
        } catch (_: Exception) {
            referrer
        }
        val values = HashMap<String, String?>()
        for (part in decoded.split('&')) {
            val eq = part.indexOf('=')
            if (eq <= 0) continue
            val k = part.substring(0, eq)
            if (k in KEYS && values[k] == null) values[k] = clean(part.substring(eq + 1))
        }
        return build(values, "install_referrer")
    }

    private fun build(values: Map<String, String?>, source: String): JSONObject? {
        if (values.values.all { it == null }) return null
        return JSONObject().apply {
            for (k in KEYS) put(k, values[k] ?: JSONObject.NULL)
            put("source", source)
        }
    }
}

/** `/config` version policy. */
internal data class VersionPolicy(
    val minSupported: String?,
    val latest: String?,
    val status: String?,
    val allowedCalls: Set<String>?,
    val allowedEvents: Set<String>?,
    val stripProperties: Boolean,
    val message: String?,
) {
    /** Effective status for [ownVersion]: the server's, else `deprecated` below the minimum. */
    fun effectiveStatus(ownVersion: String): String? =
        status ?: if (minSupported != null && compare(ownVersion, minSupported) < 0) "deprecated" else null

    val blocked: Boolean get() = status == "blocked"

    fun allows(call: String): Boolean = !blocked || call in (allowedCalls ?: DEFAULT_BLOCKED_CALLS)

    companion object {
        val NONE = VersionPolicy(null, null, null, null, null, true, null)
        val DEFAULT_BLOCKED_CALLS = setOf("config", "install", "open", "events", "opt_out", "consent", "install_ping")

        fun parse(o: JSONObject): VersionPolicy {
            fun s(k: String) = if (o.isNull(k)) null else o.optString(k).ifEmpty { null }
            val b = o.optJSONObject("blocked_instructions")
            fun set(k: String) = b?.optJSONArray(k)?.let { a -> (0 until a.length()).mapNotNull { a.opt(it) as? String }.toSet() }
            return VersionPolicy(
                minSupported = s("min_supported_version"),
                latest = s("latest_version"),
                status = s("version_status"),
                allowedCalls = set("allowed_calls"),
                allowedEvents = set("allowed_events"),
                // Without instructions a blocked SDK strips properties.
                stripProperties = b?.optBoolean("strip_event_properties", true) ?: true,
                message = b?.let { if (it.isNull("message")) null else it.optString("message").ifEmpty { null } },
            )
        }

        /** Semver comparison of the numeric `major.minor.patch` part (pre-release ignored). */
        fun compare(a: String, b: String): Int {
            fun parts(v: String) = v.substringBefore('-').substringBefore('+').split('.').map { it.toIntOrNull() ?: 0 }
            val x = parts(a)
            val y = parts(b)
            for (i in 0 until maxOf(x.size, y.size)) {
                val c = (x.getOrElse(i) { 0 }).compareTo(y.getOrElse(i) { 0 })
                if (c != 0) return c
            }
            return 0
        }
    }
}

/** `/config` `firebase_forwarding`. */
internal data class FirebaseConfig(
    val enabled: Boolean,
    val logAttributionEvent: Boolean,
    val setUserProperties: Boolean,
    val mirrorEvents: Boolean,
    val reportAppInstanceId: Boolean,
) {
    companion object {
        val OFF = FirebaseConfig(false, true, true, false, true)

        fun parse(o: JSONObject?): FirebaseConfig = if (o == null) OFF else FirebaseConfig(
            enabled = o.optBoolean("enabled", false),
            logAttributionEvent = o.optBoolean("log_attribution_event", true),
            setUserProperties = o.optBoolean("set_user_properties", true),
            mirrorEvents = o.optBoolean("mirror_events", false),
            reportAppInstanceId = o.optBoolean("report_app_instance_id", true),
        )
    }
}

/** Minor units per major unit for Firebase `value` (ISO 4217 exponents; 2 unless listed). */
internal object Money {
    private val ZERO = setOf("BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "VND", "VUV", "XAF", "XOF", "XPF")
    private val THREE = setOf("BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND")

    fun minorUnitsPerMajor(currency: String): Double = when (currency) {
        in ZERO -> 1.0
        in THREE -> 1000.0
        else -> 100.0
    }
}
