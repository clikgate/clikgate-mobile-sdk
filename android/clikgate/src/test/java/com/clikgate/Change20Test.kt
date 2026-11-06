package com.clikgate

import android.content.Intent
import android.net.Uri
import com.clikgate.FakeApi.Companion.error
import com.clikgate.FakeApi.Companion.ok
import com.clikgate.internal.DeepLinkPath
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Change 20 (S.1, R.40): `deeplink_handled` reports the handled deep link's path for the live check, with IDs,
 * emails and phone numbers replaced on the device; only in test mode or while the debug view is open; never
 * queued, metered or counted as an event.
 */
@OptIn(ClikgateInternalApi::class)
@RunWith(RobolectricTestRunner::class)
class Change20Test {
    private lateinit var env: TestEnv
    private val links = CopyOnWriteArrayList<ClikgateDeepLink>()
    private val route = "POST /v1/sdk/deeplink-handled"
    private val testKey = "cg_sdk_test_4f1c9a"
    private val liveKey = "cg_sdk_live_4f1c9a"

    @Before fun setUp() {
        env = TestEnv()
        env.api.on(route, ok(Fixtures.text("deeplink_handled_response")))
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_matched")))
        Clikgate.onDeepLink { links.add(it) }
    }

    @After fun tearDown() = env.tearDown()

    private fun reports(): List<JSONObject> = env.api.calls(route).map { env.api.body(it) }

    private fun installed(key: String) {
        env.configure(sdkKey = key)
        eventually { env.storage.installDone }
        eventually { env.core().isIdleForTests() }
    }

    private fun open(url: String) = assertTrue(Clikgate.handleIntent(null, Intent(Intent.ACTION_VIEW, Uri.parse(url))))

    private fun assertBody(fixture: String, body: JSONObject) {
        val expected = Fixtures.json(fixture)
        assertEquals(expected.getString("path"), body.getString("path"))
        assertEquals(expected.getBoolean("is_deferred"), body.getBoolean("is_deferred"))
        assertEquals(2, body.length())
        SchemaCheck.assertValid("deeplink_handled_request", body)
    }

    @Test
    fun pathCasesFromTheSharedVectors() {
        val cases = Fixtures.json("deeplink_path_cases").getJSONArray("cases")
        assertTrue(cases.length() > 20)
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            assertEquals(c.getString("path"), c.getString("expected"), DeepLinkPath.clean(c.getString("path")))
        }
    }

    @Test
    fun testModeReportsTheDirectLinkPathWithIdsReplaced() {
        installed(testKey)
        open("https://inv.myapp.com/p/dress?utm_source=x")
        eventually { reports().size == 1 }
        assertBody("deeplink_handled_request", reports().single())
        eventually { links.size == 1 }
        assertEquals("/products/42", links.single().path) // the app still gets the real path
        val r = env.api.calls(route).single()
        assertEquals(testKey, r.getHeader("Clikgate-SDK-Key"))
        assertEquals(null, r.getHeader("Idempotency-Key"))
    }

    @Test
    fun queryFragmentEmailAndUuidNeverLeaveTheDevice() {
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_debug_view")))
        installed(testKey)
        open("https://inv.myapp.com/p/dress")
        eventually { reports().size == 1 }
        assertEquals("/u/:id/orders/:id", reports().single().getString("path"))
        val raw = env.api.calls(route).single().body.clone().readUtf8()
        for (leaked in listOf("ada", "example.com", "8f14e45f", "coupon", "SAVE10", "top")) assertFalse(leaked, leaked in raw)
    }

    @Test
    fun deferredLinkIsReportedAsDeferred() {
        env.api.on("POST /v1/sdk/install", ok(Fixtures.text("install_response_deep_link_only")))
        installed(testKey)
        eventually { reports().size == 1 }
        assertBody("deeplink_handled_request_deferred", reports().single())
        eventually { links.size == 1 }
    }

    @Test
    fun liveModeSendsNothingWithoutTheDebugView() {
        env.api.on("POST /v1/sdk/install", ok(Fixtures.text("install_response_deep_link_only")))
        installed(liveKey)
        open("https://inv.myapp.com/p/dress")
        eventually { links.size == 2 }
        settle(300)
        assertTrue(env.api.calls(route).isEmpty())
    }

    @Test
    fun liveModeReportsWhileTheDebugViewIsOpen() {
        env.api.on("POST /v1/sdk/install", ok(Fixtures.text("install_response_debug_view")))
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_debug_view")))
        installed(liveKey)
        eventually { reports().size == 1 }
        open("https://inv.myapp.com/p/dress")
        eventually { reports().size == 2 }
        assertEquals(listOf(true, false), reports().map { it.getBoolean("is_deferred") })
    }

    /** Not metered: never an `/events` or `/goals` item, never queued; sent in deep-link-only and private mode. */
    @Test
    fun neverQueuedOrSentAsAnEvent() {
        for (config in listOf("config_response_deep_link_only", "config_response_private_mode")) {
            env.tearDown()
            env = TestEnv()
            env.api.on(route, ok(Fixtures.text("deeplink_handled_response")))
            env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_matched")))
            env.api.on("GET /v1/sdk/config", ok(Fixtures.text(config)))
            installed(testKey)
            open("https://inv.myapp.com/p/dress")
            eventually(message = config) { reports().size == 1 }
            env.core().flushBlocking(3_000)
            assertEquals(config, 0, env.queue.count())
            val sent = env.api.calls("POST /v1/sdk/events") + env.api.calls("POST /v1/sdk/goals")
            assertFalse(config, sent.any { "deeplink" in it.body.clone().readUtf8() })
        }
    }

    @Test
    fun aFailedReportIsDroppedAfterOneRetry() {
        env.api.on(route, error(503, """{"error":{"type":"api_error","code":"server_error","message":"x"}}"""))
        installed(testKey)
        open("https://inv.myapp.com/p/dress")
        eventually { env.api.calls(route).size == 2 }
        settle(300)
        assertEquals(2, env.api.calls(route).size)
        assertEquals(0, env.queue.count())
    }

    @Test
    fun blockedLinkIsNotReported() {
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_blocked")))
        installed(testKey)
        open("https://inv.myapp.com/offer")
        eventually { links.size == 1 }
        settle(300)
        assertTrue(env.api.calls(route).isEmpty())
    }

    @Test
    fun nothingWhileConsentIsPending() {
        env.api.on("GET /v1/sdk/config", ok(Fixtures.text("config_response_consent_required")))
        env.configure(sdkKey = testKey)
        eventually { env.core().isIdleForTests() }
        open("https://inv.myapp.com/p/dress")
        eventually { links.size == 1 } // delivered locally
        settle(300)
        assertTrue(env.api.calls(route).isEmpty())
    }
}
