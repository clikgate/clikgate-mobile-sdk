package com.clikgate

import com.clikgate.FakeApi.Companion.ok
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.mockwebserver.MockResponse
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.CopyOnWriteArrayList

/** `getInstallationHeader()`: `Clikgate-Installation: <app ID>:<installation ID>` for the app's own server. */
@RunWith(RobolectricTestRunner::class)
class InstallationHeaderTest {
    private lateinit var env: TestEnv
    private val appId = "app_01JAB3C4D5E6F7G8H9JKMNPQRS" // config_response.json

    @Before fun setUp() { env = TestEnv() }

    @After fun tearDown() = env.tearDown()

    private fun installed() {
        env.configure()
        eventually { env.storage.installDone }
        eventually { env.core().isIdleForTests() }
    }

    /** The answer of the listener form, waited for while the main looper runs. */
    private fun header(): ClikgateInstallationHeader? {
        val answers = CopyOnWriteArrayList<Any>()
        Clikgate.getInstallationHeader { answers.add(it ?: NULL) }
        eventually(message = "getInstallationHeader answer") { answers.isNotEmpty() }
        settle(50)
        assertEquals("answered once", 1, answers.size)
        return answers[0].takeUnless { it === NULL } as ClikgateInstallationHeader?
    }

    private fun installationId(): String? {
        val answers = CopyOnWriteArrayList<Any>()
        Clikgate.getInstallationId { answers.add(it ?: NULL) }
        eventually { answers.isNotEmpty() }
        return answers[0].takeUnless { it === NULL } as String?
    }

    @Test
    fun valueIsTheConfigAppIdAndTheInstallationId() {
        installed()
        val h = header()
        assertNotNull(h)
        assertEquals("Clikgate-Installation", h!!.name)
        assertEquals(ClikgateInstallationHeader.NAME, h.name)
        assertEquals("$appId:${env.storage.installationId()}", h.value)
        assertEquals("$appId:${installationId()}", h.value)
        assertTrue(h.value.substringAfter(':').matches(Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")))
        assertTrue("toString never shows the ID", !h.toString().contains(env.storage.installationId()))
    }

    @Test
    fun suspendForm() {
        installed()
        // The listener answers on the main looper, which the test thread runs while it waits.
        val r = java.util.concurrent.atomic.AtomicReference<ClikgateInstallationHeader?>()
        val t = Thread { r.set(runBlocking { withTimeout(5_000) { Clikgate.getInstallationHeader() } }) }
        t.start()
        eventually { !t.isAlive }
        val h = r.get()
        assertEquals("$appId:${env.storage.installationId()}", h?.value)
    }

    @Test
    fun calledBeforeConfigureItAnswersAfterTheFirstConfig() {
        val answers = CopyOnWriteArrayList<ClikgateInstallationHeader?>()
        Clikgate.getInstallationHeader { answers.add(it) }
        settle(200)
        assertTrue(answers.isEmpty())
        env.configure()
        eventually { answers.size == 1 }
        assertEquals("$appId:${env.storage.installationId()}", answers.single()?.value)
    }

    @Test
    fun nullAfterOptOutAndBackAfterOptIn() {
        installed()
        val before = header()
        Clikgate.setTrackingEnabled(false)
        assertNull(header())
        Clikgate.setTrackingEnabled(true)
        assertEquals(before, header())
    }

    @Test
    fun nullWhileConsentIsRequiredAndNotGiven() {
        env.api.on("GET /v1/sdk/config", ok(Fixtures.text("config_response_consent_required")))
        env.configure()
        eventually { env.api.calls("GET /v1/sdk/config").isNotEmpty() }
        assertNull(header())
    }

    @Test
    fun nullWhenConsentIsDeniedAndSetOnceGranted() {
        env.api.on("GET /v1/sdk/config", ok(Fixtures.text("config_response_consent_required")))
        env.configure()
        eventually { env.api.calls("GET /v1/sdk/config").isNotEmpty() }
        Clikgate.setConsent(attribution = ConsentState.DENIED)
        assertNull(header())
        Clikgate.setConsent(attribution = ConsentState.GRANTED)
        assertEquals("$appId:${env.storage.installationId()}", header()?.value)
    }

    @Test
    fun nullInDeepLinkOnlyMode() {
        env.api.on("GET /v1/sdk/config", ok(Fixtures.text("config_response_deep_link_only")))
        installed()
        assertNull(header())
    }

    @Test
    fun nullWhenTheConfigHasNoAppId() {
        val c = JSONObject(Fixtures.text("config_response")).apply { remove("app_id") }
        env.api.on("GET /v1/sdk/config", ok(c.toString()))
        installed()
        assertNotNull(installationId())
        assertNull(header())
    }

    @Test
    fun nullOnAnOfflineFirstLaunch() {
        env.api.on("GET /v1/sdk/config", MockResponse().setResponseCode(503))
        env.api.on("POST /v1/sdk/install", MockResponse().setResponseCode(503))
        env.configure()
        assertNotNull(installationId())
        assertNull(header())
    }

    @Test
    fun offlineRelaunchUsesTheCachedAppId() {
        installed()
        val online = header()
        assertNotNull(online)
        env.storage.configFetchedAt = 0 // stale: the next launch fetches again, and that fails
        env.api.on("GET /v1/sdk/config", MockResponse().setResponseCode(503))
        env.relaunch()
        assertEquals(online, header())
    }

    private companion object {
        val NULL = Any()
    }
}
