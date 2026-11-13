package com.clikgate.internal

import android.content.Context
import android.os.Bundle

/**
 * Firebase Analytics as seen by the SDK. The live implementation uses reflection,
 * so the SDK has no Firebase dependency; tests inject a fake.
 */
internal interface FirebaseAnalyticsBridge {
    /** True when Firebase Analytics is in the app. */
    fun isAvailable(): Boolean

    /** Params: String, Long or Double values (already within Firebase's limits). */
    fun logEvent(name: String, params: Map<String, Any>)

    fun setUserProperty(name: String, value: String)

    /** Calls [cb] once with the app instance id, or null (absent, failed, analytics storage denied). */
    fun appInstanceId(cb: (String?) -> Unit)
}

internal class ReflectionFirebaseBridge(private val context: Context) : FirebaseAnalyticsBridge {
    private val cls: Class<*>? by lazy {
        try {
            Class.forName(CLASS)
        } catch (_: Throwable) {
            null
        }
    }

    private val instance: Any? by lazy {
        try {
            cls?.getMethod("getInstance", Context::class.java)?.invoke(null, context.applicationContext)
        } catch (t: Throwable) {
            Log.d("Firebase Analytics unavailable: ${t.javaClass.simpleName}")
            null
        }
    }

    override fun isAvailable(): Boolean = instance != null

    override fun logEvent(name: String, params: Map<String, Any>) {
        val i = instance ?: return
        try {
            val b = Bundle()
            for ((k, v) in params) when (v) {
                is String -> b.putString(k, v)
                is Long -> b.putLong(k, v)
                is Double -> b.putDouble(k, v)
            }
            i.javaClass.getMethod("logEvent", String::class.java, Bundle::class.java).invoke(i, name, b)
        } catch (t: Throwable) {
            Log.w("Firebase logEvent failed: ${t.javaClass.simpleName}")
        }
    }

    override fun setUserProperty(name: String, value: String) {
        val i = instance ?: return
        try {
            i.javaClass.getMethod("setUserProperty", String::class.java, String::class.java).invoke(i, name, value)
        } catch (t: Throwable) {
            Log.w("Firebase setUserProperty failed: ${t.javaClass.simpleName}")
        }
    }

    override fun appInstanceId(cb: (String?) -> Unit) {
        val i = instance ?: return cb(null)
        try {
            taskResult(i.javaClass.getMethod("getAppInstanceId").invoke(i), cb)
        } catch (t: Throwable) {
            Log.d("Firebase getAppInstanceId failed: ${t.javaClass.simpleName}")
            cb(null)
        }
    }

    companion object {
        const val CLASS = "com.google.firebase.analytics.FirebaseAnalytics"
    }
}

/**
 * Calls [cb] once with the String result of a `com.google.android.gms.tasks.Task` (null when it
 * failed), through an `OnCompleteListener` proxy (no gms dependency).
 */
internal fun taskResult(task: Any?, cb: (String?) -> Unit) {
    var done = false
    fun finish(v: String?) {
        if (!done) {
            done = true
            cb(v)
        }
    }
    try {
        if (task == null) return finish(null)
        val listenerCls = Class.forName("com.google.android.gms.tasks.OnCompleteListener")
        val listener = java.lang.reflect.Proxy.newProxyInstance(listenerCls.classLoader, arrayOf(listenerCls)) { proxy, m, args ->
            when (m.name) {
                "hashCode" -> return@newProxyInstance System.identityHashCode(proxy)
                "equals" -> return@newProxyInstance proxy === args?.getOrNull(0)
                "toString" -> return@newProxyInstance "ClikgateTaskListener"
            }
            if (m.name == "onComplete") {
                val t = args?.getOrNull(0)
                finish(try {
                    if (t?.javaClass?.getMethod("isSuccessful")?.invoke(t) == true) t.javaClass.getMethod("getResult").invoke(t) as? String else null
                } catch (_: Throwable) {
                    null
                })
            }
            null
        }
        task.javaClass.getMethod("addOnCompleteListener", listenerCls).invoke(task, listener)
    } catch (t: Throwable) {
        Log.d("Firebase task failed: ${t.javaClass.simpleName}")
        finish(null)
    }
}

/**
 * Firebase Cloud Messaging as seen by the SDK (automatic push token). The live implementation
 * uses reflection, so the SDK has no Firebase dependency; tests inject a fake.
 */
internal interface PushTokenSource {
    /** True when Firebase Messaging is in the app. */
    fun isAvailable(): Boolean

    /** Calls [cb] once with the FCM token, or null (not initialised, failed). */
    fun token(cb: (String?) -> Unit)
}

internal class ReflectionPushTokenSource : PushTokenSource {
    private val cls: Class<*>? by lazy {
        try {
            Class.forName(CLASS)
        } catch (_: Throwable) {
            null
        }
    }

    override fun isAvailable(): Boolean = cls != null

    override fun token(cb: (String?) -> Unit) {
        val c = cls ?: return cb(null)
        try {
            // FirebaseMessaging.getInstance().getToken(): Task<String>
            val m = c.getMethod("getInstance").invoke(null)
            taskResult(c.getMethod("getToken").invoke(m), cb)
        } catch (t: Throwable) {
            Log.d("FCM token unavailable: ${t.javaClass.simpleName}")
            cb(null)
        }
    }

    companion object {
        const val CLASS = "com.google.firebase.messaging.FirebaseMessaging"
    }
}

/** Firebase / GA4 naming and size limits (checked 2026-10-22). */
internal object FirebaseLimits {
    private val NAME = Regex("^[A-Za-z][A-Za-z0-9_]{0,39}$")
    private val RESERVED = listOf("firebase_", "google_", "ga_")
    const val MAX_PARAMS = 25
    const val MAX_VALUE = 100
    const val MAX_USER_PROPERTY_VALUE = 36

    fun isValidName(name: String, maxLength: Int = 40): Boolean =
        name.length <= maxLength && NAME.matches(name) && RESERVED.none { name.startsWith(it) }

    /** Scalar params only (booleans as 0/1), first [MAX_PARAMS], strings truncated. */
    fun params(source: Map<String, Any?>): Map<String, Any> {
        val out = LinkedHashMap<String, Any>()
        for ((k, v) in source) {
            if (out.size >= MAX_PARAMS) break
            if (!isValidName(k)) continue
            when (v) {
                is String -> out[k] = v.take(MAX_VALUE)
                is Boolean -> out[k] = if (v) 1L else 0L
                is Int, is Long, is Short, is Byte -> out[k] = (v as Number).toLong()
                is Number -> out[k] = v.toDouble()
            }
        }
        return out
    }
}
