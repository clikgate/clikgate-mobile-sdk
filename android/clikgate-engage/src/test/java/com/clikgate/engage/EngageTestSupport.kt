package com.clikgate.engage

import android.os.Looper
import com.clikgate.ClikgateCallback
import com.clikgate.ClikgateError
import com.clikgate.ClikgateRequestContext
import com.clikgate.ClikgateResult
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.json.JSONObject
import org.junit.Assert.fail
import org.robolectric.Shadows.shadowOf
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

internal object Fixtures {
    fun text(name: String): String =
        requireNotNull(javaClass.classLoader!!.getResource("fixtures/$name.json")) { "fixture $name missing" }.readText()

    fun json(name: String): JSONObject = JSONObject(text(name))
}

/** A fake `/v1/sdk` API: responses per "METHOD path" (path without query); the last one repeats. */
internal class FakeApi {
    val server = MockWebServer()
    val requests = CopyOnWriteArrayList<RecordedRequest>()
    private val routes = ConcurrentHashMap<String, MutableList<MockResponse>>()

    init {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requests.add(request)
                val key = "${request.method} ${request.path!!.substringBefore('?')}"
                val list = routes[key] ?: return MockResponse().setResponseCode(404)
                    .setBody("""{"error":{"type":"not_found","code":"not_found","message":"no route $key"}}""")
                synchronized(list) { return if (list.size > 1) list.removeAt(0) else list[0] }
            }
        }
        server.start()
    }

    val baseUrl: String get() = server.url("/").toString().trimEnd('/')

    fun on(route: String, vararg responses: MockResponse) {
        routes[route] = responses.toMutableList()
    }

    fun calls(route: String): List<RecordedRequest> = requests.filter { "${it.method} ${it.path!!.substringBefore('?')}" == route }

    fun body(r: RecordedRequest): JSONObject = JSONObject(r.body.clone().readUtf8())

    companion object {
        fun ok(body: String) = MockResponse().setResponseCode(200).setHeader("Content-Type", "application/json").setBody(body)
        fun error(status: Int, body: String) = MockResponse().setResponseCode(status).setHeader("Content-Type", "application/json").setBody(body)
        fun errorCode(status: Int, code: String, extra: Map<String, Any> = emptyMap()) = error(
            status,
            JSONObject().put(
                "error",
                JSONObject().put("type", "invalid_request").put("code", code).put("message", "msg $code").put("param", "code").also { e ->
                    extra.forEach { (k, v) -> e.put(k, v) }
                },
            ).toString(),
        )
    }
}

/** Stands in for the core SDK (feature switches, request context, report-back). */
internal class FakeSource(private val api: FakeApi) : ContextSource {
    val disabled = HashSet<String>()
    var userId: String? = "user_42"
    var token: String? = "sig.1760954400"
    var sdkVersion = "android/1.0.0"
    var nativeVersion: String? = null
    var contextError: ClikgateError? = null
    val reports = CopyOnWriteArrayList<Pair<String, String?>>()
    var contextCalls = 0

    override fun isFeatureEnabled(key: String) = key !in disabled

    override fun requestContext(callback: (ClikgateResult<ClikgateRequestContext>) -> Unit) {
        contextCalls++
        val e = contextError
        if (e != null) return callback(ClikgateResult.Failure(e))
        callback(
            ClikgateResult.Success(
                ClikgateRequestContext("6a1f0c2e-0000-4000-8000-000000000001", "cg_sdk_test", "production", api.baseUrl,
                    token, userId, sdkVersion, nativeVersion),
            ),
        )
    }

    override fun reportServerError(code: String, feature: String?) {
        reports.add(code to feature)
    }
}

internal class EngageEnv {
    val api = FakeApi()
    val source = FakeSource(api)
    var now = 1_000_000L

    init {
        val c = ClikgateEngage.client
        c.source = source
        c.clock = { now }
        c.retryDelayMs = 1
        c.clearCache()
    }

    fun tearDown() {
        val c = ClikgateEngage.client
        c.source = CoreContextSource
        c.clock = System::currentTimeMillis
        c.retryDelayMs = 500
        c.clearCache()
        api.server.shutdown()
    }
}

internal fun eventually(timeoutMs: Long = 5_000, condition: () -> Boolean) {
    val end = System.currentTimeMillis() + timeoutMs
    while (System.currentTimeMillis() < end) {
        shadowOf(Looper.getMainLooper()).idle()
        if (condition()) return
        Thread.sleep(5)
    }
    shadowOf(Looper.getMainLooper()).idle()
    if (!condition()) fail("Timed out")
}

internal fun <T> await(start: (ClikgateCallback<T>) -> Unit): ClikgateResult<T> {
    var result: ClikgateResult<T>? = null
    start { result = it }
    eventually { result != null }
    return result!!
}
