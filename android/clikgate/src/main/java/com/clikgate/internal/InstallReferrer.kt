package com.clikgate.internal

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerClient.InstallReferrerResponse
import com.android.installreferrer.api.InstallReferrerStateListener
import org.json.JSONObject
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Values of Play's `ReferrerDetails`, as sent in `install_referrer`. */
internal data class ReferrerData(
    val referrer: String?,
    val referrerClickTimestampSeconds: Long,
    val installBeginTimestampSeconds: Long,
    val referrerClickTimestampServerSeconds: Long,
    val installBeginTimestampServerSeconds: Long,
    val installVersion: String?,
    val googlePlayInstant: Boolean,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("referrer", referrer ?: JSONObject.NULL)
        // Play returns 0 when a timestamp is unknown; send null rather than 1970.
        put("referrer_click_timestamp_seconds", referrerClickTimestampSeconds.orNull())
        put("install_begin_timestamp_seconds", installBeginTimestampSeconds.orNull())
        put("referrer_click_timestamp_server_seconds", referrerClickTimestampServerSeconds.orNull())
        put("install_begin_timestamp_server_seconds", installBeginTimestampServerSeconds.orNull())
        put("install_version", installVersion ?: JSONObject.NULL)
        put("google_play_instant", googlePlayInstant)
    }

    private fun Long.orNull(): Any = if (this > 0) this else JSONObject.NULL
}

/** Outcome of one connection attempt to the Play Install Referrer service. */
internal sealed class ReferrerOutcome {
    class Ok(val data: ReferrerData) : ReferrerOutcome()

    /** SERVICE_UNAVAILABLE / SERVICE_DISCONNECTED / timeout: worth retrying. */
    object Transient : ReferrerOutcome()

    /** FEATURE_NOT_SUPPORTED, DEVELOPER_ERROR, PERMISSION_ERROR, library missing: give up. */
    class Unsupported(val reason: String) : ReferrerOutcome()
}

/** One connection attempt. Implementations call [callback] exactly once, on any thread. */
internal fun interface InstallReferrerSource {
    fun fetch(callback: (ReferrerOutcome) -> Unit)
}

/** [InstallReferrerSource] backed by the Play Install Referrer library. */
internal class PlayInstallReferrerSource(private val context: Context) : InstallReferrerSource {
    override fun fetch(callback: (ReferrerOutcome) -> Unit) {
        val done = AtomicBoolean(false)
        fun finish(o: ReferrerOutcome) { if (done.compareAndSet(false, true)) callback(o) }
        Handler(Looper.getMainLooper()).post {
            val client = try {
                InstallReferrerClient.newBuilder(context).build()
            } catch (t: Throwable) {
                finish(ReferrerOutcome.Unsupported("client unavailable: ${t.javaClass.simpleName}"))
                return@post
            }
            try {
                client.startConnection(object : InstallReferrerStateListener {
                    override fun onInstallReferrerSetupFinished(responseCode: Int) {
                        val outcome = when (responseCode) {
                            InstallReferrerResponse.OK -> try {
                                val d = client.installReferrer
                                ReferrerOutcome.Ok(
                                    ReferrerData(
                                        referrer = d.installReferrer,
                                        referrerClickTimestampSeconds = d.referrerClickTimestampSeconds,
                                        installBeginTimestampSeconds = d.installBeginTimestampSeconds,
                                        referrerClickTimestampServerSeconds = d.referrerClickTimestampServerSeconds,
                                        installBeginTimestampServerSeconds = d.installBeginTimestampServerSeconds,
                                        installVersion = d.installVersion,
                                        googlePlayInstant = d.googlePlayInstantParam,
                                    ),
                                )
                            } catch (t: Throwable) {
                                ReferrerOutcome.Transient
                            }
                            InstallReferrerResponse.SERVICE_UNAVAILABLE,
                            InstallReferrerResponse.SERVICE_DISCONNECTED -> ReferrerOutcome.Transient
                            else -> ReferrerOutcome.Unsupported("response code $responseCode")
                        }
                        try { client.endConnection() } catch (_: Throwable) {}
                        finish(outcome)
                    }

                    override fun onInstallReferrerServiceDisconnected() {
                        finish(ReferrerOutcome.Transient)
                    }
                })
            } catch (t: Throwable) {
                // e.g. SecurityException on devices without the Play Store service.
                finish(ReferrerOutcome.Unsupported("startConnection failed: ${t.javaClass.simpleName}"))
            }
        }
    }
}

/**
 * Queries the install referrer once, retrying transient failures after [waitsMs] (1 s, 2 s, 4 s).
 * Calls [onResult] with the `install_referrer` JSON (or null) and whether the result is final
 * (`false` = still unavailable after all retries; the next first-launch attempt may try again).
 */
internal class InstallReferrerFetcher(
    private val source: InstallReferrerSource,
    private val scheduler: ScheduledExecutorService,
    private val waitsMs: List<Long> = listOf(1_000, 2_000, 4_000),
    private val attemptTimeoutMs: Long = 10_000,
) {
    fun fetch(onResult: (JSONObject?, Boolean) -> Unit) = attempt(0, onResult)

    private fun attempt(n: Int, onResult: (JSONObject?, Boolean) -> Unit) {
        val done = AtomicBoolean(false)
        val timeout = scheduler.schedule({
            if (done.compareAndSet(false, true)) handle(ReferrerOutcome.Transient, n, onResult)
        }, attemptTimeoutMs, TimeUnit.MILLISECONDS)
        source.fetch { outcome ->
            if (done.compareAndSet(false, true)) {
                timeout.cancel(false)
                scheduler.execute { handle(outcome, n, onResult) }
            }
        }
    }

    private fun handle(outcome: ReferrerOutcome, n: Int, onResult: (JSONObject?, Boolean) -> Unit) {
        when (outcome) {
            is ReferrerOutcome.Ok -> onResult(outcome.data.toJson(), true)
            is ReferrerOutcome.Unsupported -> {
                Log.d("Install referrer not available (${outcome.reason})")
                onResult(null, true)
            }
            ReferrerOutcome.Transient -> if (n < waitsMs.size) {
                scheduler.schedule({ attempt(n + 1, onResult) }, waitsMs[n], TimeUnit.MILLISECONDS)
            } else {
                Log.w("Install referrer service unavailable after ${n + 1} attempts")
                onResult(null, false)
            }
        }
    }
}
