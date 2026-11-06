package com.clikgate

import android.os.Handler
import android.os.Looper
import com.clikgate.internal.Core
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine

/** Plumbing for [ClikgateReferrals]. */
internal object ApiCalls {

    /** Runs [block] with the SDK core, or reports `not_configured` on the main thread. */
    inline fun <T> call(callback: ClikgateCallback<T>, block: (Core) -> Unit) {
        val core = Clikgate.coreOrNull()
        if (core == null) {
            post { callback.onResult(ClikgateResult.Failure(ClikgateError(ClikgateError.NOT_CONFIGURED, "Call Clikgate.configure() first"))) }
            return
        }
        block(core)
    }

    fun <T> invalid(callback: ClikgateCallback<T>, message: String, param: String) = post {
        callback.onResult(ClikgateResult.Failure(ClikgateError(ClikgateError.INVALID_ARGUMENT, message, param = param)))
    }

    fun post(r: () -> Unit) {
        Handler(Looper.getMainLooper()).post(r)
    }

    suspend fun <T> await(start: (ClikgateCallback<T>) -> Unit): T = suspendCoroutine { cont ->
        start { result ->
            when (result) {
                is ClikgateResult.Success -> cont.resume(result.value)
                is ClikgateResult.Failure -> cont.resumeWithException(result.error)
            }
        }
    }
}
