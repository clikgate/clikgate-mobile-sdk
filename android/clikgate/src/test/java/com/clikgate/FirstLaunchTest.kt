package com.clikgate

import com.clikgate.FakeApi.Companion.errorCode
import com.clikgate.FakeApi.Companion.ok
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.CopyOnWriteArrayList

@RunWith(RobolectricTestRunner::class)
class FirstLaunchTest {
    private lateinit var env: TestEnv

    @Before fun setUp() { env = TestEnv() }

    @After fun tearDown() = env.tearDown()

    private fun seedInstallationId() {
        env.context.getSharedPreferences("clikgate.prefs", 0).edit()
            .putString("installation_id", Fixtures.json("install_request_android").getString("installation_id")).commit()
    }

    @Test
    fun firstLaunchSendsInstallMatchingContractFixture() {
        seedInstallationId()
        Clikgate.setPushToken("fcm-token-123", PushProvider.FCM)
        // Change 03: consent set at the fixture's time, probabilistic matching on (screen), Play
        // Integrity standard request (cloud project number in config).
        Clikgate.setConsent(ConsentState.GRANTED, ConsentState.GRANTED, ConsentState.DENIED, null)
        env.attestation = object : com.clikgate.internal.AttestationProvider {
            override val type = "play_integrity"
            override fun isAvailable() = true
            override fun token(nonce: String, cloudProjectNumber: Long?, callback: (com.clikgate.internal.AttestationToken?) -> Unit) =
                callback(com.clikgate.internal.AttestationToken("eyJhbGciOi.test", if (cloudProjectNumber == 123456789012L) "standard" else "classic"))
        }
        env.api.on("GET /v1/sdk/config", FakeApi.ok(Fixtures.json("config_response").apply {
            getJSONObject("features").put("probabilistic_matching", true).getJSONObject("attestation")
                .put("android_play_integrity", "monitor").put("android_cloud_project_number", 123456789012L)
        }.toString()))
        env.api.on("POST /v1/sdk/attest/challenge", FakeApi.ok("""{"challenge":"atc_01JAB3C4D5E6F7G8H9JKMNPQRS","nonce":"bm9uY2U","expires_at":"2026-10-20T10:05:00Z"}"""))
        env.configure(env.options().copy(attestation = Attestation.PLAY_INTEGRITY_IF_AVAILABLE), clock = { 1792490280000L })

        eventually { env.api.calls("POST /v1/sdk/install").isNotEmpty() }
        val req = env.api.calls("POST /v1/sdk/install").first()
        val body = env.api.body(req)
        val expected = Fixtures.json("install_request_android")
        assertEquals(sortKeys(expected).toString(), sortKeys(body).toString())
        SchemaCheck.assertValid("install_request", body)

        assertEquals("cg_sdk_test", req.getHeader("Clikgate-SDK-Key"))
        assertEquals("android/${Clikgate.sdkVersion}", req.getHeader("Clikgate-SDK-Version"))
        assertNull(req.getHeader("Clikgate-SDK-Native-Version"))
        assertEquals(expected.getString("installation_id"), req.getHeader("Clikgate-Installation-Id"))
        assertTrue(req.getHeader("Content-Type")!!.startsWith("application/json"))

        // config is fetched before install
        assertEquals("GET", env.api.requests.first().method)
        eventually { env.storage.installDone }
        assertEquals("ins_01JAB3C4D5E6F7G8H9JKMNPQRS", env.storage.installId)
        // push token was included in /install, so no separate /push-token call
        settle(200)
        assertTrue(env.api.calls("POST /v1/sdk/push-token").isEmpty())
        assertEquals(1, env.referrer.calls.get())
    }

    @Test
    fun installationIdIsLowercaseUuidAndStable() {
        env.configure()
        eventually { env.storage.installDone }
        val id = env.storage.installationId()
        assertTrue(id.matches(Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")))
        env.relaunch()
        env.core().onForeground()
        eventually { env.api.calls("POST /v1/sdk/open").isNotEmpty() }
        assertEquals(id, env.api.calls("POST /v1/sdk/open").first().getHeader("Clikgate-Installation-Id"))
    }

    @Test
    fun deferredDeepLinkAndReferralAreDelivered() {
        env.api.on("POST /v1/sdk/install", ok(Fixtures.text("install_response_referral")))
        val links = CopyOnWriteArrayList<ClikgateDeepLink>()
        env.configure()
        // listener registered after the link arrived: buffered and delivered on registration
        eventually { env.storage.installDone }
        settle(100)
        Clikgate.onDeepLink { links.add(it) }
        eventually { links.size == 1 }
        val dl = links.first()
        assertEquals("https://inv.myapp.com/r/ADA42", dl.url)
        assertEquals("/welcome", dl.path)
        assertEquals("ADA42", dl.data["ref"])
        assertEquals("referral_welcome", dl.data["screen"])
        assertTrue(dl.isDeferred)
        assertEquals("clk_01JAB3C4D5E6F7G8H9JKMNPQRS", dl.clickId)
        assertEquals("install_referrer", dl.matchType)
        assertEquals("referral", dl.link!!.kind)
        assertEquals("Ada", dl.referral!!.referrerDisplayName)
        assertEquals("rpg_01JAB3C4D5E6F7G8H9JKMNPQRS", dl.referral!!.programId)
        assertEquals("link", dl.referral!!.source)

        val attribution = runBlocking { Clikgate.awaitAttributionForTest() }
        assertEquals("attributed", attribution.status)
        assertEquals("install_referrer", attribution.matchType)
        assertEquals(1.0, attribution.confidence!!, 0.0)
        assertEquals("ins_01JAB3C4D5E6F7G8H9JKMNPQRS", attribution.installId)
        assertEquals("lnk_01JAB3C4D5E6F7G8H9JKMNPQRS", attribution.link!!.id)
    }

    @Test
    fun attributionResolvesPendingAfterTimeoutWhenOffline() {
        env.api.on("POST /v1/sdk/install", MockResponse().setResponseCode(503))
        env.configure(env.options().copy(deferredDeepLinkTimeoutMs = 300))
        var result: ClikgateAttribution? = null
        Clikgate.attribution { result = it }
        eventually { result != null }
        assertEquals("pending", result!!.status)
        assertNull(result!!.installId)
        assertFalse(env.storage.installDone)
    }

    @Test
    fun installRetriesUntilItSucceeds() {
        env.api.on(
            "POST /v1/sdk/install",
            MockResponse().setResponseCode(500),
            errorCode(429, "rate_limited").setHeader("Retry-After", "0"),
            MockResponse().setResponseCode(502),
            ok(Fixtures.text("install_response_organic")),
        )
        env.configure()
        eventually { env.storage.installDone }
        assertEquals(4, env.api.calls("POST /v1/sdk/install").size)
        // same body (same installation id) on every attempt
        assertEquals(1, env.api.calls("POST /v1/sdk/install").map { it.body.clone().readUtf8() }.toSet().size)
    }

    @Test
    fun installIsRetriedOnNextLaunchAfterValidationError() {
        env.api.on("POST /v1/sdk/install", errorCode(422, "validation_error"), ok(Fixtures.text("install_response_organic")))
        env.configure()
        eventually { env.api.calls("POST /v1/sdk/install").size == 1 }
        settle(200)
        assertEquals(1, env.api.calls("POST /v1/sdk/install").size)
        assertFalse(env.storage.installDone)
        env.relaunch()
        eventually { env.storage.installDone }
        // referrer was queried only once across launches
        assertEquals(1, env.referrer.calls.get())
    }

    @Test
    fun pendingInstallIsPolledAndLateDeepLinkDelivered() {
        env.api.on(
            "POST /v1/sdk/install",
            ok(Fixtures.text("install_response_pending").replace("2000", "50")),
            ok(Fixtures.text("install_response_referral")),
        )
        val links = CopyOnWriteArrayList<ClikgateDeepLink>()
        Clikgate.onDeepLink { links.add(it) }
        env.configure()
        var attribution: ClikgateAttribution? = null
        Clikgate.attribution { attribution = it }
        eventually { links.size == 1 && attribution != null }
        assertEquals(2, env.api.calls("POST /v1/sdk/install").size)
        assertEquals("attributed", attribution!!.status)
        assertTrue(links.first().isDeferred)
    }

    @Test
    fun laterLaunchSendsColdOpenAndNoInstall() {
        env.configure()
        eventually { env.storage.installDone }
        env.core().onForeground() // same process as the install: no /open
        settle(200)
        assertTrue(env.api.calls("POST /v1/sdk/open").isEmpty())

        env.relaunch()
        env.core().onForeground()
        eventually { env.api.calls("POST /v1/sdk/open").isNotEmpty() }
        val open = env.api.body(env.api.calls("POST /v1/sdk/open").first())
        assertTrue(open.getBoolean("is_cold_start"))
        assertEquals("3.4.1", open.getString("app_version"))
        assertEquals(1, env.api.calls("POST /v1/sdk/install").size)
    }

    @Test
    fun foregroundAfterSessionTimeoutSendsWarmOpen() {
        var now = 1_000_000L
        env.configure(clock = { now })
        eventually { env.storage.installDone }
        env.relaunch(clock = { now })
        env.core().onForeground()
        eventually { env.api.calls("POST /v1/sdk/open").size == 1 }
        env.core().onBackground()
        now += 10 * 60_000L
        env.core().onForeground() // 10 min: same session
        settle(200)
        assertEquals(1, env.api.calls("POST /v1/sdk/open").size)
        env.core().onBackground()
        now += 31 * 60_000L
        env.core().onForeground()
        eventually { env.api.calls("POST /v1/sdk/open").size == 2 }
        assertFalse(env.api.body(env.api.calls("POST /v1/sdk/open")[1]).getBoolean("is_cold_start"))
    }

    @Test
    fun configIsCachedForAnHour() {
        var now = 5_000_000L
        env.configure(clock = { now })
        eventually { env.storage.installDone }
        env.relaunch(clock = { now })
        env.core().onForeground()
        eventually { env.api.calls("POST /v1/sdk/open").isNotEmpty() }
        assertEquals(1, env.api.calls("GET /v1/sdk/config").size)
        now += 61 * 60_000L
        env.relaunch(clock = { now })
        env.core().onForeground()
        eventually { env.api.calls("GET /v1/sdk/config").size == 2 }
    }

    @Test
    fun unknownInstallationReRunsInstall() {
        env.configure()
        eventually { env.storage.installDone }
        env.api.on("POST /v1/sdk/open", errorCode(404, "installation_unknown"), ok("{}"))
        env.relaunch()
        env.core().onForeground()
        eventually { env.api.calls("POST /v1/sdk/install").size == 2 }
        eventually { env.storage.installDone }
    }

    @Test
    fun invalidSdkKeyStopsAllCalls() {
        env.api.on("POST /v1/sdk/install", errorCode(401, "invalid_sdk_key"))
        env.configure()
        eventually { env.api.calls("POST /v1/sdk/install").size == 1 }
        Clikgate.goal("signup")
        Clikgate.identifyUser(customerId = "user_42")
        settle(300)
        assertEquals(1, env.api.calls("POST /v1/sdk/install").size)
        assertEquals(2, env.api.requests.size) // config + install, nothing after
    }

    @Test
    fun invalidSdkKeyOnConfigStopsBeforeInstall() {
        env.api.on("GET /v1/sdk/config", errorCode(401, "invalid_sdk_key"))
        env.configure()
        eventually { env.api.requests.size == 1 }
        settle(300)
        assertEquals(1, env.api.requests.size)
        // next launch tries again
        env.api.on("GET /v1/sdk/config", FakeApi.ok(Fixtures.text("config_response")))
        env.relaunch()
        eventually { env.storage.installDone }
    }

    @Test
    fun wrapperHeadersReportBothVersions() {
        @OptIn(ClikgateInternalApi::class)
        Clikgate.setWrapper("flutter", "1.2.3")
        env.configure()
        eventually { env.api.calls("POST /v1/sdk/install").isNotEmpty() }
        val req = env.api.calls("POST /v1/sdk/install").first()
        assertEquals("flutter/1.2.3", req.getHeader("Clikgate-SDK-Version"))
        assertEquals("android/${Clikgate.sdkVersion}", req.getHeader("Clikgate-SDK-Native-Version"))
    }

    @Test
    fun configureTwiceIsIgnored() {
        env.configure()
        val first = env.core()
        assertFalse(Clikgate.configureInternal(env.context, "cg_sdk_other", env.options(), env.deps(), false))
        assertTrue(first === env.core())
        assertNotNull(Clikgate.coreOrNull())
    }

    private fun sortKeys(o: JSONObject): JSONObject {
        val out = JSONObject()
        o.keys().asSequence().sorted().forEach { k ->
            val v = o.get(k)
            out.put(k, if (v is JSONObject) sortKeys(v) else v)
        }
        return out
    }
}

/** awaitAttribution() with the Robolectric main looper pumped while waiting. */
internal suspend fun Clikgate.awaitAttributionForTest(): ClikgateAttribution {
    var result: ClikgateAttribution? = null
    attribution { result = it }
    eventually { result != null }
    return result!!
}
