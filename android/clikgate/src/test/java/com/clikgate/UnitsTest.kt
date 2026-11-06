package com.clikgate

import com.clikgate.internal.Backoff
import com.clikgate.internal.Emulator
import com.clikgate.internal.HttpClient
import com.clikgate.internal.InstallReferrerFetcher
import com.clikgate.internal.Json
import com.clikgate.internal.ReferrerData
import com.clikgate.internal.ReferrerOutcome
import com.clikgate.internal.SdkConfig
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.random.Random

@RunWith(RobolectricTestRunner::class)
class UnitsTest {

    // ---- install referrer

    private fun fetch(source: FakeReferrerSource): Pair<JSONObject?, Boolean> {
        val exec = Executors.newSingleThreadScheduledExecutor()
        val latch = CountDownLatch(1)
        var result: Pair<JSONObject?, Boolean>? = null
        InstallReferrerFetcher(source, exec, listOf(1, 2, 4), attemptTimeoutMs = 500).fetch { j, f ->
            result = j to f
            latch.countDown()
        }
        assertTrue(latch.await(5, TimeUnit.SECONDS))
        exec.shutdown()
        return result!!
    }

    @Test
    fun referrerDetailsAreSerialisedWithServerTimestamps() {
        val (json, final) = fetch(FakeReferrerSource())
        assertTrue(final)
        val expected = Fixtures.json("install_request_android").getJSONObject("install_referrer")
        for (k in expected.keys()) assertEquals(k, expected.get(k).toString(), json!!.get(k).toString())
        // passed through unmodified (still URL-encoded)
        assertTrue(json!!.getString("referrer").startsWith("cg_click_id%3Dclk_"))
    }

    @Test
    fun unknownTimestampsAreNull() {
        val json = ReferrerData("utm_source=google-play&utm_medium=organic", 0, 0, 0, 0, null, false).toJson()
        assertTrue(json.isNull("referrer_click_timestamp_seconds"))
        assertTrue(json.isNull("install_begin_timestamp_server_seconds"))
        assertTrue(json.isNull("install_version"))
        assertEquals("utm_source=google-play&utm_medium=organic", json.getString("referrer"))
    }

    @Test
    fun serviceUnavailableIsRetriedUpToThreeTimes() {
        val ok = ReferrerOutcome.Ok(FakeReferrerSource.fixtureReferrer())
        val src = FakeReferrerSource(listOf(ReferrerOutcome.Transient, ReferrerOutcome.Transient, ok))
        val (json, final) = fetch(src)
        assertTrue(final)
        assertEquals(3, src.calls.get())
        assertTrue(json != null)

        val down = FakeReferrerSource(listOf(ReferrerOutcome.Transient))
        val (none, finalDown) = fetch(down)
        assertNull(none)
        assertFalse(finalDown) // not final: a later first-launch attempt may query again
        assertEquals(4, down.calls.get()) // 1 + 3 retries
    }

    @Test
    fun featureNotSupportedIsFinalWithoutRetry() {
        val src = FakeReferrerSource(listOf(ReferrerOutcome.Unsupported("response code 2")))
        val (json, final) = fetch(src)
        assertNull(json)
        assertTrue(final)
        assertEquals(1, src.calls.get())
    }

    @Test
    fun referrerServiceThatNeverAnswersTimesOut() {
        val silent = object : FakeReferrerSourceBase() {}
        val exec = Executors.newSingleThreadScheduledExecutor()
        val latch = CountDownLatch(1)
        var final: Boolean? = null
        InstallReferrerFetcher(silent, exec, listOf(1), attemptTimeoutMs = 50).fetch { _, f -> final = f; latch.countDown() }
        assertTrue(latch.await(5, TimeUnit.SECONDS))
        assertEquals(false, final)
        exec.shutdown()
    }

    internal open class FakeReferrerSourceBase : com.clikgate.internal.InstallReferrerSource {
        override fun fetch(callback: (ReferrerOutcome) -> Unit) {}
    }

    // ---- HTTP error mapping

    @Test
    fun errorBodiesAreMapped() {
        val e = HttpClient.failure(404, Fixtures.text("error_code_not_found"), null)
        assertEquals("code_not_found", e.error.code)
        assertEquals("code", e.error.param)
        assertEquals(404, e.error.status)
        assertFalse(e.retryable)

        val rl = HttpClient.failure(429, Fixtures.text("error_rate_limited"), "7")
        assertEquals("rate_limited", rl.error.code)
        assertNull(rl.error.param)
        assertTrue(rl.retryable)
        assertEquals(7_000L, rl.retryAfterMs)

        assertTrue(HttpClient.failure(503, "<html>", null).let { it.retryable && it.error.code == "server_error" })
        assertTrue(HttpClient.failure(408, "", null).retryable)
        assertTrue(HttpClient.failure(409, """{"error":{"type":"conflict","code":"install_in_progress","message":"m"}}""", "1").retryable)
        assertFalse(HttpClient.failure(422, """{"error":{"type":"invalid_request","code":"validation_error","message":"m"}}""", null).retryable)
        assertEquals("invalid_sdk_key", HttpClient.failure(401, "", null).error.code)
    }

    @Test
    fun backoffIsExponentialCappedWithJitter() {
        val b = Backoff(random = Random(42))
        for (attempt in 0..10) {
            val base = minOf(60_000L, 1_000L shl attempt)
            val d = b.delayMs(attempt)
            assertTrue("attempt $attempt: $d", d >= (base * 0.8).toLong() && d <= (base * 1.2).toLong())
        }
        assertTrue(Backoff().delayMs(100) <= 72_000)
    }

    // ---- JSON model mapping from fixtures

    @Test
    fun parsesInstallResponses() {
        val organic = Fixtures.json("install_response_organic")
        assertNull(Json.installDeepLink(organic))
        val a = Json.attribution(organic.getJSONObject("attribution"), "ins_1")
        assertEquals("organic", a.status)
        assertNull(a.matchType)
        assertNull(a.link)
        assertFalse(a.isAttributed)

        val referral = Fixtures.json("install_response_referral")
        val dl = Json.installDeepLink(referral)!!
        assertEquals("2026-10-20T10:00:01Z", dl.referral!!.createdAt)
        assertEquals("rfr_01JAB3C4D5E6F7G8H9JKMNPQRS", dl.referral!!.referrerId)
        assertTrue(Json.attribution(referral.getJSONObject("attribution"), null).isAttributed)
        assertEquals("2026-10-20T09:59:00Z", Json.attribution(referral.getJSONObject("attribution"), null).clickedAt)
    }

    @Test
    fun parsesConfig() {
        val c = SdkConfig.parse(Fixtures.json("config_response"))
        assertEquals(setOf("inv.myapp.com", "ciz.to"), c.linkDomains)
        assertEquals(20, c.flushAtCount)
        assertEquals(15, c.flushIntervalSeconds)
        assertEquals(1000, c.maxQueueEvents)
        assertEquals(1_048_576L, c.maxQueueBytes)
        assertEquals(30, c.sessionTimeoutMinutes)
        assertEquals("off", c.playIntegrity)
        assertEquals(SdkConfig.DEFAULT, SdkConfig.parse(JSONObject()))
    }

    @Test
    fun emulatorHeuristics() {
        assertTrue(Emulator.isEmulator("google/sdk_gphone64_arm64/emu64a:14/UE1A/1:userdebug/dev-keys", "sdk_gphone64_arm64", "Google", "google", "emu64a", "sdk_gphone64_arm64", "ranchu"))
        assertTrue(Emulator.isEmulator("generic/sdk/generic:5.0/x", "Android SDK built for x86", "unknown", "generic", "generic", "sdk", "goldfish"))
        assertTrue(Emulator.isEmulator("x", "Custom Phone", "Genymotion", "generic", "vbox86p", "vbox86p", "vbox86"))
        assertFalse(Emulator.isEmulator("google/husky/husky:14/AP1A/1:user/release-keys", "Pixel 8 Pro", "Google", "google", "husky", "husky", "husky"))
        assertFalse(Emulator.isEmulator("samsung/a54xnsxx/a54x:14/UP1A/1:user/release-keys", "SM-A546E", "samsung", "samsung", "a54x", "a54xnsxx", "s5e8835"))
    }
}
