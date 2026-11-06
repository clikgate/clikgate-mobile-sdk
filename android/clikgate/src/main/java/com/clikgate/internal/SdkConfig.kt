package com.clikgate.internal

import org.json.JSONObject

/** The parts of `GET /v1/sdk/config` the Android SDK uses. Defaults = "everything off". */
internal data class SdkConfig(
    val linkDomains: Set<String> = emptySet(),
    val playIntegrity: String = "off",
    val restrictedMode: Boolean = false,
    val maxBatchSize: Int = 100,
    val flushIntervalSeconds: Int = 15,
    val flushAtCount: Int = 20,
    val maxQueueEvents: Int = 1000,
    val maxQueueBytes: Long = 1_048_576,
    val reattestationIntervalDays: Int = 7,
    val sessionTimeoutMinutes: Int = 30,
    /**
     * Boolean entries of `features` (v3 feature switches, already resolved for this app); null
     * for the built-in default config (no config fetched or cached yet).
     */
    val features: Map<String, Boolean>? = null,
    // ---- consent and version policy ----
    /** `features.probabilistic_matching` (Android sends `screen` only with it and attribution consent). */
    val probabilisticMatching: Boolean = false,
    /** `features.attestation.android_cloud_project_number`. */
    val cloudProjectNumber: Long? = null,
    /** `consent`, null when the server sent none (or no config yet). */
    val consent: ConsentConfig? = null,
    val versionPolicy: VersionPolicy = VersionPolicy.NONE,
    val firebase: FirebaseConfig = FirebaseConfig.OFF,
    // ---- private mode ----
    /** `private_mode` (absent = off): no identify, no event properties / revenue; goals as usual. */
    val privateMode: Boolean = false,
    /** `allow_labels` (absent = on): false in private mode without "Allow labels in private mode". */
    val allowLabels: Boolean = true,
) {
    /**
     * `Clikgate.isFeatureEnabled`: the server's value when present, else the catalogue default
     * (missing keys are on for [DEFAULT_ON], off otherwise;
     * unknown keys are off).
     */
    fun isFeatureEnabled(key: String): Boolean = features?.get(key) ?: (key in DEFAULT_ON)

    companion object {
        val DEFAULT = SdkConfig()

        /** Features that count as on when the server (or an older server) doesn't list them. */
        val DEFAULT_ON = setOf("referrals", "leaderboards", "offline_codes", "app_attribution", "deep_linking")

        private fun booleanFeatures(features: JSONObject): Map<String, Boolean> {
            val out = LinkedHashMap<String, Boolean>()
            val keys = features.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                (features.opt(k) as? Boolean)?.let { out[k] = it }
            }
            return out
        }

        /** Host name of a link domain as compared with URL hosts: trimmed, lowercased, no scheme or path. */
        fun normalizeDomain(domain: String): String {
            var d = domain.trim().lowercase()
            val scheme = d.indexOf("://")
            if (scheme >= 0) d = d.substring(scheme + 3)
            val slash = d.indexOf('/')
            if (slash >= 0) d = d.substring(0, slash)
            return d
        }

        fun parse(o: JSONObject): SdkConfig {
            // Optional (pre-Part-3 servers omit it); anything but an array of strings is ignored.
            val domains = o.optJSONArray("link_domains")?.let { a ->
                (0 until a.length()).mapNotNull { i ->
                    (a.opt(i) as? String)?.let(::normalizeDomain)?.takeIf { it.isNotEmpty() }
                }.toSet()
            } ?: emptySet()
            val features = o.optJSONObject("features") ?: JSONObject()
            val attestation = features.optJSONObject("attestation") ?: JSONObject()
            val b = o.optJSONObject("batching") ?: JSONObject()
            val d = DEFAULT
            return SdkConfig(
                linkDomains = domains,
                playIntegrity = attestation.optString("android_play_integrity", "off").ifEmpty { "off" },
                restrictedMode = features.optBoolean("restricted_mode", false),
                maxBatchSize = b.optInt("max_batch_size", d.maxBatchSize).coerceIn(1, 100),
                flushIntervalSeconds = b.optInt("flush_interval_seconds", d.flushIntervalSeconds).coerceAtLeast(1),
                flushAtCount = b.optInt("flush_at_count", d.flushAtCount).coerceAtLeast(1),
                maxQueueEvents = b.optInt("max_queue_events", d.maxQueueEvents).coerceAtLeast(1),
                maxQueueBytes = b.optLong("max_queue_bytes", d.maxQueueBytes).coerceAtLeast(1024),
                reattestationIntervalDays = o.optInt("reattestation_interval_days", d.reattestationIntervalDays),
                sessionTimeoutMinutes = o.optInt("session_timeout_minutes", d.sessionTimeoutMinutes).coerceAtLeast(1),
                features = o.optJSONObject("features")?.let(::booleanFeatures),
                probabilisticMatching = features.optBoolean("probabilistic_matching", false),
                cloudProjectNumber = attestation.optLong("android_cloud_project_number", 0L).takeIf { it > 0 },
                consent = ConsentConfig.parse(o.optJSONObject("consent")),
                versionPolicy = VersionPolicy.parse(o),
                firebase = FirebaseConfig.parse(o.optJSONObject("firebase_forwarding")),
                privateMode = o.optBoolean("private_mode", false),
                allowLabels = o.optBoolean("allow_labels", true),
            )
        }
    }
}
