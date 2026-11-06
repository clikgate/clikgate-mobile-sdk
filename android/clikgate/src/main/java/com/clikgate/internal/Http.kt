package com.clikgate.internal

import com.clikgate.ClikgateError
import org.json.JSONObject
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import kotlin.random.Random

internal class ApiRequest(
    val method: String,
    /** Path below the base URL, e.g. `/v1/sdk/install` (may include a query string). */
    val path: String,
    val body: JSONObject? = null,
    val headers: Map<String, String> = emptyMap(),
    /** No `Clikgate-Installation-Id` header (consent buffering, `/install-ping`). */
    val anonymous: Boolean = false,
)

internal sealed class ApiResult {
    class Success(val status: Int, val body: JSONObject) : ApiResult()

    class Failure(
        val error: ClikgateError,
        val retryable: Boolean,
        /** Server-requested delay (`Retry-After`), if any. */
        val retryAfterMs: Long? = null,
    ) : ApiResult()
}

/** Minimal JSON-over-HTTP client on HttpURLConnection (no extra dependency). */
internal class HttpClient(
    private val baseUrl: String,
    private val defaultHeaders: () -> Map<String, String>,
    private val connectTimeoutMs: Int = 10_000,
    private val readTimeoutMs: Int = 10_000,
) {
    fun execute(req: ApiRequest): ApiResult {
        var conn: HttpURLConnection? = null
        try {
            conn = (URL(baseUrl.trimEnd('/') + req.path).openConnection() as HttpURLConnection).apply {
                requestMethod = req.method
                connectTimeout = connectTimeoutMs
                readTimeout = readTimeoutMs
                useCaches = false
                instanceFollowRedirects = false
                setRequestProperty("Accept", "application/json")
                for ((k, v) in defaultHeaders()) if (!(req.anonymous && k == "Clikgate-Installation-Id")) setRequestProperty(k, v)
                for ((k, v) in req.headers) setRequestProperty(k, v)
            }
            val payload = req.body?.toString()?.toByteArray(Charsets.UTF_8)
            if (payload != null) {
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                conn.setFixedLengthStreamingMode(payload.size)
                conn.outputStream.use { it.write(payload) }
            }
            val status = conn.responseCode
            val text = readBody(if (status >= 400) conn.errorStream else conn.inputStream)
            Log.v("${req.method} ${req.path.substringBefore('?')} -> $status")
            if (status in 200..299) {
                val json = if (text.isBlank()) JSONObject() else try {
                    JSONObject(text)
                } catch (e: Exception) {
                    return ApiResult.Failure(ClikgateError(ClikgateError.SERVER_ERROR, "Invalid JSON response", status), retryable = false)
                }
                return ApiResult.Success(status, json)
            }
            return failure(status, text, conn.getHeaderField("Retry-After"))
        } catch (e: SocketTimeoutException) {
            return ApiResult.Failure(ClikgateError(ClikgateError.TIMEOUT, "Request timed out", cause = e), retryable = true)
        } catch (e: IOException) {
            return ApiResult.Failure(ClikgateError(ClikgateError.NETWORK_ERROR, e.message ?: "Network error", cause = e), retryable = true)
        } catch (e: Exception) {
            return ApiResult.Failure(ClikgateError(ClikgateError.NETWORK_ERROR, e.message ?: "Request failed", cause = e), retryable = true)
        } finally {
            conn?.disconnect()
        }
    }

    private fun readBody(stream: InputStream?): String =
        stream?.use { it.readBytes().toString(Charsets.UTF_8) } ?: ""

    companion object {
        fun failure(status: Int, body: String, retryAfterHeader: String?): ApiResult.Failure {
            var code: String? = null
            var message: String? = null
            var param: String? = null
            var offlineTouchId: String? = null
            try {
                val err = JSONObject(body).optJSONObject("error")
                if (err != null) {
                    code = err.optString("code").takeIf { it.isNotEmpty() }
                    message = err.optString("message").takeIf { it.isNotEmpty() }
                    param = if (err.isNull("param")) null else err.optString("param").takeIf { it.isNotEmpty() }
                    // /codes/redeem: the touch was recorded although the referral failed.
                    offlineTouchId = if (err.isNull("offline_touch_id")) null else err.optString("offline_touch_id").takeIf { it.isNotEmpty() }
                }
            } catch (_: Exception) {
            }
            val resolvedCode = code ?: when {
                status >= 500 -> ClikgateError.SERVER_ERROR
                status == 429 -> "rate_limited"
                status == 401 -> ClikgateError.INVALID_SDK_KEY
                else -> "http_$status"
            }
            val retryable = status == 408 || status == 429 || status >= 500 || resolvedCode == "install_in_progress"
            val retryAfterMs = retryAfterHeader?.trim()?.toLongOrNull()?.takeIf { it >= 0 }?.times(1000)
            return ApiResult.Failure(
                ClikgateError(resolvedCode, message ?: "HTTP $status", status, param, offlineTouchId = offlineTouchId),
                retryable = retryable,
                retryAfterMs = retryAfterMs,
            )
        }
    }
}

/** Exponential backoff `min(max, base * 2^attempt)` with ±20 % jitter (API contract). */
internal class Backoff(
    private val baseMs: Long = 1_000,
    private val maxMs: Long = 60_000,
    private val jitter: Double = 0.2,
    private val random: Random = Random.Default,
) {
    fun delayMs(attempt: Int): Long {
        val exp = if (attempt >= 30) maxMs else minOf(maxMs, baseMs shl attempt)
        val factor = 1.0 + (random.nextDouble() * 2 - 1) * jitter
        return (exp * factor).toLong().coerceAtLeast(0)
    }
}
