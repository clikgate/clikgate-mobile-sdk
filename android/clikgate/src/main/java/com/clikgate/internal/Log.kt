package com.clikgate.internal

import com.clikgate.LogLevel

/** Logcat logger. Never pass secrets (SDK key, push / identity tokens) to it. */
internal object Log {
    private const val TAG = "Clikgate"

    @Volatile
    var level: LogLevel = LogLevel.WARN

    private fun enabled(l: LogLevel) = level != LogLevel.NONE && l.ordinal >= level.ordinal

    fun v(msg: String) { if (enabled(LogLevel.VERBOSE)) safe { android.util.Log.v(TAG, msg) } }
    fun d(msg: String) { if (enabled(LogLevel.DEBUG)) safe { android.util.Log.d(TAG, msg) } }
    fun i(msg: String) { if (enabled(LogLevel.INFO)) safe { android.util.Log.i(TAG, msg) } }
    fun w(msg: String, t: Throwable? = null) { if (enabled(LogLevel.WARN)) safe { android.util.Log.w(TAG, msg, t) } }
    fun e(msg: String, t: Throwable? = null) { if (enabled(LogLevel.ERROR)) safe { android.util.Log.e(TAG, msg, t) } }

    private inline fun safe(block: () -> Unit) {
        try { block() } catch (_: Throwable) { /* android.util.Log missing in plain JVM tests */ }
    }
}
