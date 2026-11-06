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

    /** Delivers the context or a [ClikgateError] (any thread). */
    fun requestContext(callback: (ClikgateResult<ClikgateRequestContext>) -> Unit)

    fun reportServerError(code: String, feature: String?)
}

internal object CoreContextSource : ContextSource {
    override fun isFeatureEnabled(key: String): Boolean = Clikgate.isFeatureEnabled(key)

    override fun requestContext(callback: (ClikgateResult<ClikgateRequestContext>) -> Unit) =
        Clikgate.requestContext { callback(it) }

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
) {
    private class Entry(val at: Long, val value: Any?)

    private val cache = ConcurrentHashMap<String, Entry>()

    /** HTTP attempts made by Engage itself (tests; the platform HTTP stack may add its own). */
    val attempts = AtomicInteger()
    private val network: ExecutorService = Executors.newFixedThreadPool(2) { r ->
        Thread(r, "clikgate-engage-" + threadCount.incrementAndGet()).apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())

    fun clearCache() = cache.clear()

    fun <T> fail(callback: ClikgateCallback<T>, error: ClikgateError) {
        main.post { callback.onResult(ClikgateResult.Failure(error)) }
    }

    fun <T> invalid(callback: ClikgateCallback<T>, message: String, param: String) =
        fail(callback, ClikgateError(ClikgateError.INVALID_ARGUMENT, message, param = param))

    /**
     * Runs one call. [userCall]: needs an identified installation (`not_identified` otherwise, no
     * network). [cacheable]: GET whose result may be served from the 60 s cache. [write]: clears the
     * cache. [kind] selects the [EngageJson.parse] mapping (which may throw [ClikgateError]).
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
        callback: ClikgateCallback<T>,
    ) {
        val src = source
        // An empty feature (share events) has no switch.
        if (feature.isNotEmpty() && !src.isFeatureEnabled(feature)) return fail(callback, featureDisabled(feature))
        src.requestContext { r ->
            when (r) {
                is ClikgateResult.Failure -> fail(callback, r.error)
                is ClikgateResult.Success -> {
                    val ctx = r.value
                    if (userCall && ctx.customerUserId == null) {
                        return@requestContext fail(
                            callback,
                            ClikgateError(EngageErrors.NOT_IDENTIFIED, "Call Clikgate.identifyUser() before this call"),
                        )
                    }
                    val key = "${ctx.installationId}|${ctx.customerUserId}|${ctx.identityToken != null}|$method $path"
                    if (cacheable) {
                        val hit = cache[key]
                        if (hit != null && clock() - hit.at in 0 until CACHE_TTL_MS) {
                            @Suppress("UNCHECKED_CAST")
                            val value = hit.value as T
                            main.post { callback.onResult(ClikgateResult.Success(value)) }
                            return@requestContext
                        }
                    }
                    if (write) cache.clear()
                    network.execute {
                        val result: ClikgateResult<T> = execute(src, ctx, feature, method, path, body, kind)
                        if (result is ClikgateResult.Success) {
                            if (cacheable) cache[key] = Entry(clock(), result.value)
                            if (write) cache.clear()
                        }
                        main.post { callback.onResult(result) }
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
    ): ClikgateResult<T> {
        var response = send(ctx, method, path, body)
        if (isNetworkFailure(response)) {
            // At most one retry, for network errors only (interactive calls).
            try {
                Thread.sleep(retryDelayMs)
            } catch (_: InterruptedException) {
            }
            response = send(ctx, method, path, body)
        }
        return when (response) {
            is ClikgateResult.Failure -> {
                if (response.error.code in REPORTED_CODES) src.reportServerError(response.error.code, response.error.feature)
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
                        ClikgateResult.Success(EngageJson.parse(kind, json) as T)
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

    private fun send(ctx: ClikgateRequestContext, method: String, path: String, body: JSONObject?): ClikgateResult<JSONObject> {
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

        fun enc(s: String): String = URLEncoder.encode(s, "UTF-8")

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
