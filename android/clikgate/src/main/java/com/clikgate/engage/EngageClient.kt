@file:OptIn(com.clikgate.ClikgateInternalApi::class)

package com.clikgate.engage

import android.os.Handler
import android.os.Looper
import com.clikgate.Clikgate
import com.clikgate.ClikgateCallback
import com.clikgate.ClikgateError
import com.clikgate.ClikgateRequestContext
import com.clikgate.ClikgateResult
import com.clikgate.engage.EngageJson.str
import org.json.JSONObject
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** Where Engage gets feature switches and the request context (the core SDK; replaced in tests). */
internal interface ContextSource {
    fun isFeatureEnabled(key: String): Boolean

    /**
     * Delivers the context or a [ClikgateError] (any thread). [wait] false: the stored context at
     * once (same gates), without waiting for the install or a pending identify.
     */
    fun requestContext(wait: Boolean, callback: (ClikgateResult<ClikgateRequestContext>) -> Unit)

    fun reportServerError(code: String, feature: String?)
}

internal object CoreContextSource : ContextSource {
    override fun isFeatureEnabled(key: String): Boolean = Clikgate.isFeatureEnabled(key)

    override fun requestContext(wait: Boolean, callback: (ClikgateResult<ClikgateRequestContext>) -> Unit) =
        Clikgate.requestContext(wait) { callback(it) }

    override fun reportServerError(code: String, feature: String?) = Clikgate.reportServerError(code, feature)
}

/**
 * The Engage call pipeline: feature switch → request context → identity check →
 * 60 s in-memory read cache → HTTP (one retry for network errors only) → typed result on the main
 * thread.
 */
internal class EngageClient(
    @Volatile var source: ContextSource = CoreContextSource,
    @Volatile var clock: () -> Long = System::currentTimeMillis,
    @Volatile var retryDelayMs: Long = 500,
) : com.clikgate.internal.LinkPreparer {
    /**
     * The core's "prepare this program's link" listener after `identifyUser()` (the core saves
     * every link answer for the customer it was made for). Here rather than in a class of its own: the Engage
     * size budget.
     */
    override fun prepareLink(programId: String) = call<ReferralLink>(
        "referrals", "POST", "/v1/sdk/referrals/link", JSONObject().put("program_id", programId),
        userCall = true, cacheable = false, write = true, kind = EngageJson.LINK, callback = null, byToken = false,
    )

    /** Registers [prepareLink] with the core (the core keeps only the first registration of a configured SDK). */
    fun prepareLinks() {
        Clikgate.coreOrNull()?.setIdentifyListener(this)
    }

    init {
        prepareLinks()
    }

    private class Entry(val at: Long, val value: Any?)

    private val cache = ConcurrentHashMap<String, Entry>()

    /** HTTP attempts made by Engage itself (tests; the platform HTTP stack may add its own). */
    val attempts = AtomicInteger()
    private val network: ExecutorService = Executors.newFixedThreadPool(2) { r ->
        Thread(r, "clikgate-engage-" + threadCount.incrementAndGet()).apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())

    fun clearCache() = cache.clear()

    /**
     * [EngageReferrals.myLink]: the link saved on the device for the signed-in customer at once,
     * then a background refresh (at most once per [CACHE_TTL_MS] per program and customer) through
     * the stats read, which saves the answer; with nothing saved, that read answers.
     */
    fun myLink(programId: String, path: String, callback: ClikgateCallback<ReferralLink>) {
        // Null when the feature is off, tracking is off or nobody is signed in: the read below says why
        val core = Clikgate.coreOrNull()
        val saved = core?.savedLink(programId)
        if (saved != null) {
            deliver(callback, ClikgateResult.Success(EngageJson.referralLink(saved)))
            // When the saved link (program and customer) was last refreshed, kept with the read cache
            val key = "$programId|${core.linkToken()}"
            val last = cache[key]
            if (last != null && clock() - last.at in 0 until CACHE_TTL_MS) return
            cache[key] = Entry(clock(), null)
        }
        call("referrals", "GET", path, null, userCall = true, cacheable = false, write = false, kind = EngageJson.LINK,
            callback = if (saved != null) null else callback, byToken = true)
    }

    fun <T> fail(callback: ClikgateCallback<T>?, error: ClikgateError) = deliver(callback, ClikgateResult.Failure(error))

    /** [callback] null: a background call whose answer only the core keeps (saved referral links). */
    fun <T> deliver(callback: ClikgateCallback<T>?, result: ClikgateResult<T>) {
        if (callback != null) main.post { callback.onResult(result) }
    }

    fun <T> invalid(callback: ClikgateCallback<T>, message: String, param: String) =
        fail(callback, ClikgateError(ClikgateError.INVALID_ARGUMENT, message, param = param))

    /**
     * Runs one call. [userCall]: needs an identified installation (`not_identified` otherwise, no
     * network). [cacheable]: GET whose result may be served from the 60 s cache. [write]: clears the
     * cache. [kind] selects the [EngageJson.parse] mapping (which may throw [ClikgateError]).
     * [byToken]: a read the server can answer from the identity token alone. With a stored customer
     * ID and token it is sent at once with `Clikgate-Customer-User-Id` (no wait for the install or
     * identify); `installation_unknown` / `not_identified` (an older server, or a race) retry once
     * through the waiting context. Without a token it waits as other calls do.
     */
    fun <T> call(
        feature: String,
        method: String,
        path: String,
        body: JSONObject?,
        userCall: Boolean,
        cacheable: Boolean,
        write: Boolean,
        kind: Int,
        callback: ClikgateCallback<T>?,
        byToken: Boolean,
    ) {
        val src = source
        // An empty feature (share events) has no switch.
        if (feature.isNotEmpty() && !src.isFeatureEnabled(feature)) return fail(callback, featureDisabled(feature))
        src.requestContext(!byToken) { r ->
            when (r) {
                is ClikgateResult.Failure -> fail(callback, r.error)
                is ClikgateResult.Success -> {
                    val ctx = r.value
                    // Without a token the server needs the install and identify: wait as other calls do
                    // (without a customer ID, not_identified below answers at once).
                    if (byToken && ctx.customerUserId != null && ctx.identityToken == null) {
                        return@requestContext call(feature, method, path, body, userCall, cacheable, write, kind, callback, false)
                    }
                    if (userCall && ctx.customerUserId == null) {
                        return@requestContext fail(
                            callback,
                            ClikgateError(EngageErrors.NOT_IDENTIFIED, "Call Clikgate.identifyUser() before this call"),
                        )
                    }
                    // The customer ID is part of the key: one user's answer is never served to another.
                    val key = "${ctx.installationId}|${ctx.customerUserId}|${ctx.identityToken != null}|$method $path"
                    if (cacheable) {
                        val hit = cache[key]
                        if (hit != null && clock() - hit.at in 0 until CACHE_TTL_MS) {
                            @Suppress("UNCHECKED_CAST")
                            val value = hit.value as T
                            deliver(callback, ClikgateResult.Success(value))
                            return@requestContext
                        }
                    }
                    if (write) cache.clear()
                    network.execute {
                        val result: ClikgateResult<T> = execute(src, ctx, feature, method, path, body, kind, byToken)
                        val code = result.errorOrNull()?.code
                        if (byToken && (code == INSTALLATION_UNKNOWN || code == EngageErrors.NOT_IDENTIFIED)) {
                            // An older server ignores the header, or the install / identify is still on its way
                            return@execute call(feature, method, path, body, userCall, cacheable, write, kind, callback, false)
                        }
                        if (result is ClikgateResult.Success) {
                            if (cacheable) cache[key] = Entry(clock(), result.value)
                            if (write) cache.clear()
                        }
                        deliver(callback, result)
                    }
                }
            }
        }
    }

    private fun <T> execute(
        src: ContextSource,
        ctx: ClikgateRequestContext,
        feature: String,
        method: String,
        path: String,
        body: JSONObject?,
        kind: Int,
        byToken: Boolean,
    ): ClikgateResult<T> {
        var response = send(ctx, method, path, body, byToken)
        if (isNetworkFailure(response)) {
            // At most one retry, for network errors only (interactive calls).
            try {
                Thread.sleep(retryDelayMs)
            } catch (_: InterruptedException) {
            }
            response = send(ctx, method, path, body, byToken)
        }
        return when (response) {
            is ClikgateResult.Failure -> {
                val code = response.error.code
                // Retried through the waiting path, which reports it if it still holds
                if (code in REPORTED_CODES && !(byToken && code == INSTALLATION_UNKNOWN)) src.reportServerError(code, response.error.feature)
                response
            }
            is ClikgateResult.Success -> {
                val json = response.value
                if (EngageJson.isFeatureDisabled(json)) {
                    val key = json.str("feature") ?: feature
                    src.reportServerError(ClikgateError.FEATURE_DISABLED, key)
                    if (key != feature) src.reportServerError(ClikgateError.FEATURE_DISABLED, feature)
                    ClikgateResult.Failure(featureDisabled(key))
                } else {
                    try {
                        @Suppress("UNCHECKED_CAST")
                        val value = EngageJson.parse(kind, json) as T
                        // A link answer is saved for the customer it was made for
                        if (kind == EngageJson.LINK || kind == EngageJson.STATS) {
                            Clikgate.coreOrNull()?.saveLinkAnswer(body, ctx.customerUserId, json)
                        }
                        ClikgateResult.Success(value)
                    } catch (e: ClikgateError) {
                        ClikgateResult.Failure(e)
                    } catch (e: Exception) {
                        ClikgateResult.Failure(ClikgateError(ClikgateError.SERVER_ERROR, "Unexpected response: ${e.message}"))
                    }
                }
            }
        }
    }

    /** Transport failures (the only `network_error` / `timeout` source): retried once. */
    private fun isNetworkFailure(r: ClikgateResult<JSONObject>): Boolean {
        val code = r.errorOrNull()?.code ?: return false
        return code == ClikgateError.NETWORK_ERROR || code == ClikgateError.TIMEOUT
    }

    private fun send(ctx: ClikgateRequestContext, method: String, path: String, body: JSONObject?, byToken: Boolean): ClikgateResult<JSONObject> {
        attempts.incrementAndGet()
        var conn: HttpURLConnection? = null
        try {
            conn = (URL(ctx.apiBaseUrl.trimEnd('/') + path).openConnection() as HttpURLConnection).apply {
                requestMethod = method
                connectTimeout = TIMEOUT_MS
                readTimeout = TIMEOUT_MS
                useCaches = false
                instanceFollowRedirects = false
                setRequestProperty("Accept", "application/json")
                for ((k, v) in ctx.headers()) setRequestProperty(k, v)
                if (byToken) setRequestProperty("Clikgate-Customer-User-Id", pctEncode(ctx.customerUserId!!))
            }
            val payload = body?.toString()?.toByteArray(Charsets.UTF_8)
            if (payload != null) {
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                conn.setFixedLengthStreamingMode(payload.size)
                conn.outputStream.use { it.write(payload) }
            }
            val status = conn.responseCode
            val text = read(if (status >= 400) conn.errorStream else conn.inputStream)
            if (status in 200..299) {
                return try {
                    ClikgateResult.Success(if (text.isBlank()) JSONObject() else JSONObject(text))
                } catch (_: Exception) {
                    ClikgateResult.Failure(ClikgateError(ClikgateError.SERVER_ERROR, "Invalid JSON response", status))
                }
            }
            return ClikgateResult.Failure(errorFrom(status, text))
        } catch (e: SocketTimeoutException) {
            return ClikgateResult.Failure(ClikgateError(ClikgateError.TIMEOUT, "Request timed out", cause = e))
        } catch (e: IOException) {
            return ClikgateResult.Failure(ClikgateError(ClikgateError.NETWORK_ERROR, e.message ?: "Network error", cause = e))
        } finally {
            conn?.disconnect()
        }
    }

    private fun read(stream: InputStream?): String = stream?.use { it.readBytes().toString(Charsets.UTF_8) } ?: ""

    companion object {
        const val CACHE_TTL_MS: Long = 60_000
        private const val TIMEOUT_MS = 10_000
        private val threadCount = AtomicInteger()

        /** Errors the core SDK must hear about (global rules). */
        private val REPORTED_CODES = setOf(
            ClikgateError.FEATURE_DISABLED, ClikgateError.INVALID_SDK_KEY, ClikgateError.SDK_DISABLED, "installation_unknown",
        )

        fun featureDisabled(feature: String) = ClikgateError(
            ClikgateError.FEATURE_DISABLED,
            "The '$feature' feature is switched off for this app",
            feature = feature,
        )

        fun errorFrom(status: Int, text: String): ClikgateError {
            var err: JSONObject? = null
            try {
                err = JSONObject(text).optJSONObject("error")
            } catch (_: Exception) {
            }
            val code = err?.str("code")?.takeIf { it.isNotEmpty() } ?: when {
                status >= 500 -> ClikgateError.SERVER_ERROR
                status == 429 -> EngageErrors.RATE_LIMITED
                status == 401 -> ClikgateError.INVALID_SDK_KEY
                else -> "http_$status"
            }
            return ClikgateError(
                code = code,
                message = err?.str("message")?.takeIf { it.isNotEmpty() } ?: "HTTP $status",
                status = status,
                param = err?.str("param")?.takeIf { it.isNotEmpty() },
                feature = err?.str("feature")?.takeIf { it.isNotEmpty() },
                offlineTouchId = err?.str("offline_touch_id")?.takeIf { it.isNotEmpty() },
            )
        }

        private const val INSTALLATION_UNKNOWN = "installation_unknown"

        fun enc(s: String): String = URLEncoder.encode(s, "UTF-8")

        /** Percent-encoded UTF-8; only `A-Z a-z 0-9 - . _ ~` stay as they are (form encoding fixed up). */
        fun pctEncode(s: String): String = enc(s).replace("+", "%20").replace("*", "%2A").replace("%7E", "~")

        fun query(vararg q: Pair<String, String?>): String {
            val sb = StringBuilder()
            for ((k, v) in q) {
                if (v == null) continue
                sb.append(if (sb.isEmpty()) '?' else '&').append(k).append('=').append(enc(v))
            }
            return sb.toString()
        }
    }
}
