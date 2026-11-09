package com.clikgate

import android.content.Context
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import com.clikgate.internal.Backoff
import com.clikgate.internal.BackgroundScheduler
import com.clikgate.internal.Deps
import com.clikgate.internal.DeviceInfo
import com.clikgate.internal.EventQueue
import com.clikgate.internal.InstallReferrerSource
import com.clikgate.internal.ReferrerData
import com.clikgate.internal.ReferrerOutcome
import com.clikgate.internal.Storage
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.json.JSONObject
import org.junit.Assert.fail
import org.robolectric.Shadows.shadowOf
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.random.Random

/** Shared contract fixtures from ../shared/fixtures (on the test classpath). */
internal object Fixtures {
    fun text(name: String): String =
        requireNotNull(javaClass.classLoader!!.getResource("fixtures/$name.json")) { "fixture $name missing" }.readText()

    fun json(name: String): JSONObject = JSONObject(text(name))
}

/** Device values matching shared/fixtures/install_request_android.json. */
internal open class FakeDevice(context: Context) : DeviceInfo(context) {
    override val appVersion = "3.4.1"
    override val osVersion = "14"
    override val deviceModel = "Pixel 8"
    override val locale = "en-NG"
    override val timezone = "Africa/Lagos"
    override fun screen(): JSONObject = JSONObject().put("w", 1080).put("h", 2400).put("scale", 2.625)
    override fun installerPackage() = "com.android.vending"
    override fun isEmulator() = false
    override fun isRooted() = false
}

/** Install referrer returning the fixture's referrer details. */
internal class FakeReferrerSource(private val outcomes: List<ReferrerOutcome> = listOf(ReferrerOutcome.Ok(fixtureReferrer()))) :
    InstallReferrerSource {
    val calls = AtomicInteger()
    override fun fetch(callback: (ReferrerOutcome) -> Unit) {
        val n = calls.getAndIncrement()
        callback(outcomes[minOf(n, outcomes.size - 1)])
    }

    companion object {
        fun fixtureReferrer(): ReferrerData {
            val r = Fixtures.json("install_request_android").getJSONObject("install_referrer")
            return ReferrerData(
                referrer = r.getString("referrer"),
                referrerClickTimestampSeconds = r.getLong("referrer_click_timestamp_seconds"),
                installBeginTimestampSeconds = r.getLong("install_begin_timestamp_seconds"),
                referrerClickTimestampServerSeconds = r.getLong("referrer_click_timestamp_server_seconds"),
                installBeginTimestampServerSeconds = r.getLong("install_begin_timestamp_server_seconds"),
                installVersion = r.getString("install_version"),
                googlePlayInstant = r.getBoolean("google_play_instant"),
            )
        }
    }
}

internal class RecordingBackground : BackgroundScheduler {
    val scheduled = AtomicInteger()
    override fun scheduleFlush() {
        scheduled.incrementAndGet()
    }
}

/**
 * A fake Clikgate API. Responses are configured per "METHOD path" (path without query); each
 * entry is a queue whose last element repeats. Defaults: config + organic install + ok bodies.
 */
internal class FakeApi {
    val server = MockWebServer()
    val requests = CopyOnWriteArrayList<RecordedRequest>()
    private val routes = ConcurrentHashMap<String, MutableList<MockResponse>>()

    init {
        on("GET /v1/sdk/config", ok(Fixtures.text("config_response")))
        on("POST /v1/sdk/install", ok(Fixtures.text("install_response_organic")))
        on("POST /v1/sdk/open", ok("""{"open_id":"aop_01JAB3C4D5E6F7G8H9JKMNPQRS","uninstall_status":"installed"}"""))
        on("POST /v1/sdk/goals", ok("""{"accepted":1,"duplicates":0,"rejected":[]}"""))
        on("POST /v1/sdk/identify", ok(Fixtures.text("identify_response")))
        on("POST /v1/sdk/push-token", ok("""{"ok":true}"""))
        on("POST /v1/sdk/opt-out", ok("""{"opt_out":true}"""))
        on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_unmatched")))
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requests.add(request)
                val key = "${request.method} ${request.path!!.substringBefore('?')}"
                val list = routes[key] ?: return MockResponse().setResponseCode(404)
                    .setBody("""{"error":{"type":"not_found","code":"not_found","message":"no route $key"}}""")
                synchronized(list) {
                    return if (list.size > 1) list.removeAt(0) else list[0]
                }
            }
        }
        server.start()
    }

    val baseUrl: String get() = server.url("/").toString().trimEnd('/')

    fun on(route: String, vararg responses: MockResponse) {
        routes[route] = responses.toMutableList()
    }

    fun calls(route: String): List<RecordedRequest> =
        requests.filter { "${it.method} ${it.path!!.substringBefore('?')}" == route }

    fun body(r: RecordedRequest): JSONObject = JSONObject(r.body.clone().readUtf8())

    fun shutdown() = server.shutdown()

    companion object {
        fun ok(body: String) = MockResponse().setResponseCode(200).setHeader("Content-Type", "application/json").setBody(body)
        fun error(status: Int, body: String) = MockResponse().setResponseCode(status).setHeader("Content-Type", "application/json").setBody(body)
        fun errorCode(status: Int, code: String, param: String? = null) = error(
            status,
            JSONObject().put("error", JSONObject().put("type", "invalid_request").put("code", code).put("message", "msg $code").put("param", param ?: JSONObject.NULL)).toString(),
        )
    }
}

internal class TestEnv {
    val context: Context = ApplicationProvider.getApplicationContext()
    val api = FakeApi()
    val background = RecordingBackground()
    var referrer = FakeReferrerSource()
    var attestation: com.clikgate.internal.AttestationProvider? = null
    var device: DeviceInfo = FakeDevice(context)
    var firebase: com.clikgate.internal.FirebaseAnalyticsBridge? = null
    var browser: com.clikgate.internal.BrowserOpener? = null
    val storage = Storage(context)
    val queue = EventQueue(context)

    fun deps(clock: () -> Long = System::currentTimeMillis) = Deps(
        storage = storage,
        queue = queue,
        device = device,
        referrerSource = referrer,
        attestation = attestation,
        background = background,
        clock = clock,
        backoff = Backoff(baseMs = 1, maxMs = 5, jitter = 0.0, random = Random(1)),
        referrerWaitsMs = listOf(1, 2, 4),
        installWaitForReferralMs = 3_000,
        firebase = firebase,
        appInstanceIdWaitMs = 500,
        browser = browser,
    )

    fun options(vararg domains: String = arrayOf("inv.myapp.com")) =
        ClikgateOptions(linkDomains = domains.toList(), apiBaseUrl = api.baseUrl, logLevel = LogLevel.NONE, deferredDeepLinkTimeoutMs = 3_000)

    fun configure(options: ClikgateOptions = options(), clock: () -> Long = System::currentTimeMillis, sdkKey: String = "cg_sdk_test") {
        Clikgate.configureInternal(context, sdkKey, options, deps(clock), registerLifecycle = false)
    }

    /** Simulates an app relaunch: drops the in-memory SDK, keeps prefs and the event DB. */
    fun relaunch(options: ClikgateOptions = options(), clock: () -> Long = System::currentTimeMillis) {
        Clikgate.resetForTesting()
        configure(options, clock)
    }

    fun core() = Clikgate.coreOrNull()!!

    fun tearDown() {
        Clikgate.resetForTesting()
        api.shutdown()
        queue.close()
    }
}

/** Polls [condition], running main-looper tasks in between, until true or [timeoutMs]. */
internal fun eventually(timeoutMs: Long = 5_000, message: String = "condition", condition: () -> Boolean) {
    val end = System.currentTimeMillis() + timeoutMs
    while (System.currentTimeMillis() < end) {
        shadowOf(Looper.getMainLooper()).idle()
        if (condition()) return
        Thread.sleep(10)
    }
    shadowOf(Looper.getMainLooper()).idle()
    if (!condition()) fail("Timed out waiting for $message")
}

/** Waits [ms] while running main-looper tasks (to assert something did NOT happen). */
internal fun settle(ms: Long = 300) {
    val end = System.currentTimeMillis() + ms
    while (System.currentTimeMillis() < end) {
        shadowOf(Looper.getMainLooper()).idle()
        Thread.sleep(10)
    }
}
