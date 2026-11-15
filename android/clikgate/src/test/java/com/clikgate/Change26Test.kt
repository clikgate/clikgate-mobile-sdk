package com.clikgate

import android.util.Base64
import com.clikgate.FakeApi.Companion.error
import com.clikgate.FakeApi.Companion.ok
import com.clikgate.engage.ClikgateEngage
import com.clikgate.engage.ReferralLink
import com.clikgate.internal.AppInstallFacts
import com.clikgate.internal.Backoff
import com.clikgate.internal.ExistingUserFields
import com.clikgate.internal.HttpClient
import com.clikgate.internal.ReferrerData
import com.clikgate.internal.ReferrerOutcome
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
import java.util.Date
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlin.random.Random

/**
 * Change 26 (existing users): what the first `/install` says about when the app arrived on the phone
 * (EX.3, R.3-R.8), the typed existing-user error (RF.1), the server's wait with jitter (R.11) and the
 * referral links Engage prepares after identifyUser() (R.28).
 */
@RunWith(RobolectricTestRunner::class)
class Change26Test {
    private lateinit var env: TestEnv

    // 2025-03-02T09:17:45Z, 2026-11-10T08:30:00Z
    private val firstInstall = 1_740_907_065_000L
    private val lastUpdate = 1_794_299_400_000L

    private inner class Device(
        private val facts: AppInstallFacts,
        private val debuggable: Boolean = false,
    ) : FakeDevice(env.context) {
        override fun installFacts() = facts
        override val isDebuggableApp: Boolean get() = debuggable
    }

    private val facts = AppInstallFacts(firstInstall, lastUpdate, 341, preinstalled = false, androidId = "9774d56d682e549c")

    @Before fun setUp() {
        env = TestEnv()
        env.api.on("GET /v1/sdk/config", ok(Fixtures.text("config_response_existing_users")))
    }

    @After fun tearDown() = env.tearDown()

    private fun installBody(options: ClikgateOptions = env.options()): JSONObject {
        env.configure(options)
        eventually { env.api.calls("POST /v1/sdk/install").isNotEmpty() }
        return env.api.body(env.api.calls("POST /v1/sdk/install").first())
    }

    private fun noPlayReferrer() {
        val r = FakeReferrerSource.fixtureReferrer()
        env.referrer = FakeReferrerSource(listOf(ReferrerOutcome.Ok(ReferrerData(r.referrer, r.referrerClickTimestampSeconds, r.installBeginTimestampSeconds, r.referrerClickTimestampServerSeconds, 0, r.installVersion, false))))
    }

    private fun <T> await(start: (ClikgateCallback<T>) -> Unit): ClikgateResult<T> {
        var result: ClikgateResult<T>? = null
        start { result = it }
        eventually(8_000) { result != null }
        return result!!
    }

    // ------------------------------------------------------------------ EX.3

    @Test
    fun firstInstallSendsThePhonesInstallFacts() {
        env.device = Device(facts)
        val b = installBody()
        SchemaCheck.assertValid("install_request", b)
        // Play's server time (install_begin_timestamp_server_seconds = 1760954460) wins over the phone's clock
        assertEquals("play_install_begin_server", b.getString("platform_installed_source"))
        assertEquals("2025-10-20T10:00:00Z", b.getString("platform_installed_at"))
        assertEquals("2026-11-10T08:00:00Z", b.getString("android_last_update_at"))
        assertTrue(b.getBoolean("android_updated_since_install"))
        assertEquals(341L, b.getLong("android_version_code"))
        assertEquals("store", b.getString("install_channel"))
        assertEquals("com.android.vending", b.getString("installer_package"))
        assertFalse(b.getBoolean("debuggable"))
        assertFalse(b.getBoolean("preinstalled"))
        assertTrue(b.has("device_time"))
        assertFalse(b.has("existing_user_hint"))
        assertFalse(b.has("installed_before_start"))
        // R.8: the keyed hash, never ANDROID_ID itself
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(Base64.decode("c2FsdC1mb3ItYXBw", Base64.DEFAULT), "HmacSHA256")) }
        val expected = mac.doFinal("9774d56d682e549c".toByteArray()).joinToString("") { "%02x".format(it) }
        assertEquals(expected, b.getString("android_device_key"))
        assertFalse(b.toString().contains("9774d56d682e549c"))
    }

    @Test
    fun withoutPlaysTimeThePhonesFirstInstallTimeIsUsedRoundedToTheHour() {
        noPlayReferrer()
        env.device = Device(facts.copy(lastUpdateTime = firstInstall + 30_000))
        val b = installBody()
        assertEquals("android_first_install_time", b.getString("platform_installed_source"))
        assertEquals("2025-03-02T09:00:00Z", b.getString("platform_installed_at"))
        // R.4: worked out from the exact times (30 s apart = the build carrying the SDK), then rounded
        assertFalse(b.getBoolean("android_updated_since_install"))
    }

    @Test
    fun theHintAndPreloadedAppsAreReported() {
        noPlayReferrer()
        env.device = Device(facts.copy(preinstalled = true))
        val b = installBody(env.options().copy(existingUser = true))
        SchemaCheck.assertValid("install_request", b)
        assertTrue(b.getBoolean("existing_user_hint"))
        assertTrue(b.getBoolean("preinstalled"))
    }

    @Test
    fun channelIsDebugForDebuggableBuildsAndSideloadWithoutAStore() {
        assertEquals("debug", ExistingUserFields.installChannel("com.android.vending", true))
        assertEquals("sideload", ExistingUserFields.installChannel(null, false))
        assertEquals("sideload", ExistingUserFields.installChannel("com.google.android.packageinstaller", false))
        assertEquals("store", ExistingUserFields.installChannel("com.transsion.store", false))
    }

    @Test
    fun theDebugInstallDateIsUsedOnlyInDebuggableBuildsWithATestKey() {
        noPlayReferrer()
        val debugAt = Date(1_700_000_000_000L) // 2023-11-14T22:13:20Z
        env.api.on("GET /v1/sdk/config", ok(JSONObject(Fixtures.text("config_response_existing_users")).put("environment", "sandbox").toString()))
        env.device = Device(facts, debuggable = true)
        val b = installBody(env.options().copy(debugPlatformInstalledAt = debugAt))
        assertEquals("2023-11-14T22:00:00Z", b.getString("platform_installed_at"))
        assertEquals("debug", b.getString("install_channel"))
    }

    @Test
    fun theDebugInstallDateIsIgnoredInReleaseBuilds() {
        noPlayReferrer()
        env.api.on("GET /v1/sdk/config", ok(JSONObject(Fixtures.text("config_response_existing_users")).put("environment", "sandbox").toString()))
        env.device = Device(facts, debuggable = false)
        val b = installBody(env.options().copy(debugPlatformInstalledAt = Date(1_700_000_000_000L)))
        assertEquals("2025-03-02T09:00:00Z", b.getString("platform_installed_at"))
    }

    // ------------------------------------------------------------------ R.3

    @Test
    fun optedOutSendsOnlyWhetherTheAppWasHereBeforeTheStartDate() {
        noPlayReferrer()
        env.device = Device(facts)
        // A cached config with the start date (2026-11-01): the opted-out install doesn't fetch one
        env.storage.configJson = Fixtures.text("config_response_existing_users")
        env.storage.trackingEnabled = false
        val b = installBody()
        SchemaCheck.assertValid("install_request", b)
        assertTrue(b.getBoolean("installed_before_start"))
        assertFalse(b.getBoolean("existing_user_hint"))
        for (field in listOf("platform_installed_at", "android_last_update_at", "device_time", "android_device_key", "android_version_code")) {
            assertFalse("$field must not be sent when opted out", b.has(field))
        }
    }

    @Test
    fun attributionConsentDeniedSendsNoDates() {
        val i = ExistingUserFields.Inputs(
            facts = facts, installerPackage = "com.android.vending", debuggable = false, playInstallBeginServerSeconds = 0,
            nowMs = lastUpdate, hint = true, datesAllowed = false, startAtMs = firstInstall - 1, deviceKeySalt = "c2FsdA==",
            debugInstalledAtMs = null, testEnvironment = false,
        )
        val b = JSONObject().also { ExistingUserFields.put(it, i) }
        assertEquals(setOf("install_channel", "debuggable", "existing_user_hint", "installed_before_start"), b.keys().asSequence().toSet())
        assertFalse(b.getBoolean("installed_before_start"))
        // No start date yet: nothing to compare with
        val none = JSONObject().also { ExistingUserFields.put(it, ExistingUserFields.Inputs(facts, null, false, 0, lastUpdate, false, false, null, null, null, false)) }
        assertFalse(none.has("installed_before_start"))
    }

    // ------------------------------------------------------------------ RF.1

    @Test
    fun applyCodeFromAnExistingUserFailsWithTheTypedError() {
        env.api.on("POST /v1/sdk/referrals/apply-code", error(409, Fixtures.text("error_existing_user")))
        env.configure()
        eventually { env.storage.installDone }
        val err = await<Referral> { Clikgate.referrals.applyCode("rpg_01JAB3C4D5E6F7G8H9JKMNPQRS", "ADA42", it) }.errorOrNull()
        assertTrue(err is ExistingUserError)
        assertEquals(ClikgateError.EXISTING_USER, err!!.code)
        assertEquals(409, err.status)
        assertEquals(1, env.api.calls("POST /v1/sdk/referrals/apply-code").size)
    }

    @Test
    fun theExistingUserStatusIsReadFromTheInstallAnswer() {
        env.api.on("POST /v1/sdk/install", ok(Fixtures.text("install_response_existing_user")))
        env.configure()
        eventually { env.storage.installDone }
        val a = env.core().currentAttribution()
        assertEquals(ClikgateAttribution.STATUS_ORGANIC, a.status)
        assertTrue(a.isExistingUser)
        assertFalse(a.isAttributed)
    }

    // ------------------------------------------------------------------ R.11

    @Test
    fun aWaitInTheErrorBodyIsHonouredWithJitter() {
        val f = HttpClient.failure(429, Fixtures.text("error_rate_limited_retry_after"), "5")
        assertEquals(30_000L, f.retryAfterMs)
        assertTrue(f.retryable)
        val backoff = Backoff(random = Random(7))
        repeat(50) {
            val d = backoff.withJitter(30_000)
            assertTrue("$d", d in 30_000..37_500)
        }
        // Header only (older servers)
        assertEquals(5_000L, HttpClient.failure(429, Fixtures.text("error_rate_limited"), "5").retryAfterMs)
    }

    // ------------------------------------------------------------------ R.28

    private fun configureForLinks() {
        env.api.on("POST /v1/sdk/referrals/link", ok(Fixtures.text("referral_link_response")))
        env.configure()
        eventually { env.storage.installDone }
        ClikgateEngage.client.source = com.clikgate.engage.CoreContextSource
        ClikgateEngage.clearCache()
    }

    private val program = "rpg_01JAB3C4D5E6F7G8H9JKMNPQRS"

    @Test
    fun theLinkIsPreparedAfterIdentifyAndAnsweredOfflineThenClearedOnSignOut() {
        configureForLinks()
        ClikgateEngage.client.prepareLinks() // Engage used after configure() in this launch
        Clikgate.identifyUser(customerId = "user_42", identityToken = "sig.1760954400")
        eventually(message = "link prepared") { env.core().savedLink(program) != null }
        assertEquals(1, env.api.calls("POST /v1/sdk/referrals/link").size)
        assertFalse("the customer ID is never saved in clear", env.storage.savedLinksJson!!.contains("user_42"))

        // Offline: the saved link answers at once
        env.api.on("POST /v1/sdk/referrals/link", error(503, """{"error":{"type":"server_error","code":"server_error","message":"down"}}"""))
        val link = await<ReferralLink> { ClikgateEngage.referrals.createLink(program, callback = it) }.getOrThrow()
        assertEquals("ADA42X", link.code)
        assertEquals("https://inv.myapp.com/a8K2bq", link.shortUrl)

        // Another customer on the same phone never sees it
        val first = JSONObject(env.storage.savedLinksJson!!).getString("c")
        Clikgate.identifyUser(customerId = "user_77")
        eventually { env.storage.savedLinksJson?.let { JSONObject(it).getString("c") != first } ?: true }

        // Sign-out clears it
        env.api.on("POST /v1/sdk/referrals/link", ok(Fixtures.text("referral_link_response")))
        eventually(message = "link for user_77") { env.core().savedLink(program) != null }
        Clikgate.identifyUser(customerId = null)
        eventually { env.storage.savedLinksJson == null }
    }

    @Test
    fun withoutASavedLinkCreateLinkCallsTheApiAndSavesTheAnswer() {
        env.api.on("GET /v1/sdk/config", ok(Fixtures.text("config_response")))
        configureForLinks()
        Clikgate.identifyUser(customerId = "user_42")
        eventually { env.core().isIdleForTests() }
        val link = await<ReferralLink> { ClikgateEngage.referrals.createLink(program, callback = it) }.getOrThrow()
        assertEquals("ADA42X", link.code)
        assertNotNull(env.core().savedLink(program))
    }

    @Test
    fun aDeviceKeyNeedsBothTheIdAndTheSalt() {
        assertNull(ExistingUserFields.deviceKey(null, "c2FsdA=="))
        assertNull(ExistingUserFields.deviceKey("abc", null))
        assertEquals(64, ExistingUserFields.deviceKey("abc", "c2FsdA==")!!.length)
    }
}
