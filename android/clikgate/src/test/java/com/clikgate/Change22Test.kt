package com.clikgate

import com.clikgate.FakeApi.Companion.ok
import android.content.Intent
import android.net.Uri
import okhttp3.mockwebserver.MockResponse
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Change 22: one method, `goal()` (R.9 `received`), and `getInstallationId()` for identity Path B (I.7, R.26).
 */
@RunWith(RobolectricTestRunner::class)
class Change22Test {
    private lateinit var env: TestEnv

    @Before fun setUp() { env = TestEnv() }

    @After fun tearDown() = env.tearDown()

    private fun installed() {
        env.configure()
        eventually { env.storage.installDone }
        eventually { env.core().isIdleForTests() }
    }

    /** The answer of the callback form, waited for while the main looper runs. */
    private fun installationId(): String? {
        val answers = CopyOnWriteArrayList<Any>()
        Clikgate.getInstallationId { answers.add(it ?: NULL) }
        eventually(message = "getInstallationId answer") { answers.isNotEmpty() }
        settle(50)
        assertEquals("answered once", 1, answers.size)
        return answers[0].takeUnless { it === NULL } as String?
    }

    private val sentInstallationId get() = env.api.requests.first { it.path!!.startsWith("/v1/sdk/install") }.getHeader("Clikgate-Installation-Id")

    // ------------------------------------------------------------------ R.9 received

    @Test
    fun receivedIsASuccessAndIsNotRetried() {
        env.api.on("POST /v1/sdk/goals", ok(Fixtures.text("goals_response_received")))
        installed()
        val results = ConcurrentHashMap<String, GoalResult>()
        Clikgate.goal("level_completed", reference = "APP-7") { results["new"] = it }
        Clikgate.goal("old_signup", reference = "APP-8") { results["archived"] = it }
        assertTrue(env.core().flushBlocking(3_000))
        eventually { results.size == 2 }
        assertEquals(GoalResult(GoalStatus.RECEIVED, "not_counted_yet", null, false), results["new"])
        assertEquals(GoalResult(GoalStatus.RECEIVED, "goal_archived", GoalKind.STANDARD, false), results["archived"])
        assertEquals(0, env.queue.count())
        settle(300)
        assertEquals(1, env.api.calls("POST /v1/sdk/goals").size)
        assertEquals("received", GoalStatus.RECEIVED.value)
    }

    // ------------------------------------------------------------------ getInstallationId

    @Test
    fun installationIdIsTheOneSentToClikgate() {
        installed()
        val id = installationId()
        assertNotNull(id)
        assertEquals(sentInstallationId, id)
        assertTrue(id!!.matches(Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")))
        // Stable across launches.
        env.relaunch()
        assertEquals(id, installationId())
    }

    @Test
    fun calledBeforeConfigureItAnswersAfterConfigure() {
        val answers = CopyOnWriteArrayList<String?>()
        Clikgate.getInstallationId { answers.add(it) }
        settle(200)
        assertTrue(answers.isEmpty())
        env.configure()
        eventually { answers.size == 1 }
        eventually { env.storage.installDone }
        assertEquals(sentInstallationId, answers.single())
    }

    @Test
    fun worksOfflineOnTheFirstLaunch() {
        env.api.on("GET /v1/sdk/config", MockResponse().setResponseCode(503))
        env.api.on("POST /v1/sdk/install", MockResponse().setResponseCode(503))
        env.configure()
        val id = installationId()
        assertNotNull(id)
        assertEquals(env.storage.installationId(), id)
    }

    @Test
    fun nullAfterOptOutAndBackAfterOptIn() {
        installed()
        val id = installationId()
        Clikgate.setTrackingEnabled(false)
        assertNull(installationId())
        Clikgate.setTrackingEnabled(true)
        assertEquals(id, installationId())
    }

    @Test
    fun nullWhileConsentIsRequiredAndNotGivenOrDenied() {
        env.api.on("GET /v1/sdk/config", ok(Fixtures.text("config_response_consent_required")))
        env.configure()
        eventually { env.api.calls("GET /v1/sdk/config").isNotEmpty() }
        assertNull(installationId()) // unknown in a required region: nothing identifying yet
        Clikgate.setConsent(attribution = ConsentState.DENIED)
        assertNull(installationId())
        Clikgate.setConsent(attribution = ConsentState.GRANTED)
        assertEquals(env.storage.installationId(), installationId())
    }

    @Test
    fun nullInDeepLinkOnlyMode() {
        env.api.on("GET /v1/sdk/config", ok(Fixtures.text("config_response_deep_link_only")))
        installed()
        assertNull(installationId())
    }

    @Test
    fun allowedInPrivateMode() {
        env.api.on("GET /v1/sdk/config", ok(Fixtures.text("config_response_private_mode")))
        installed()
        assertEquals(sentInstallationId, installationId())
    }

    // ------------------------------------------------------------------ R.6 deeplink_handled for banner taps

    private fun openLive(resolveFixture: String) {
        env.api.on("POST /v1/sdk/deeplink-handled", ok(Fixtures.text("deeplink_handled_response")))
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text(resolveFixture)))
        env.configure(sdkKey = "cg_sdk_live_4f1c9a")
        eventually { env.storage.installDone }
        eventually { env.core().isIdleForTests() }
        assertTrue(Clikgate.handleIntent(null, Intent(Intent.ACTION_VIEW, Uri.parse("https://inv.myapp.com/products/42?ref=banner"))))
    }

    @Test
    fun liveModeReportsTheRightScreenForABannerTapThatMeasuresIt() {
        openLive("resolve_response_banner_right_screen")
        eventually { env.api.calls("POST /v1/sdk/deeplink-handled").size == 1 }
        val body = env.api.body(env.api.calls("POST /v1/sdk/deeplink-handled").single())
        SchemaCheck.assertValid("deeplink_handled_request", body)
        val expected = Fixtures.json("deeplink_handled_request_banner")
        for (k in listOf("path", "is_deferred", "click_id")) assertEquals(k, expected.get(k), body.get(k))
        assertEquals(3, body.length())
        assertEquals(0, env.queue.count()) // never queued, never a goal
        assertTrue(env.api.calls("POST /v1/sdk/goals").isEmpty())
    }

    @Test
    fun liveModeWithoutTheBannerFlagReportsNothing() {
        openLive("resolve_response_matched")
        eventually { env.api.calls("POST /v1/sdk/resolve").isNotEmpty() }
        settle(300)
        assertTrue(env.api.calls("POST /v1/sdk/deeplink-handled").isEmpty())
    }

    private companion object {
        val NULL = Any()
    }
}
