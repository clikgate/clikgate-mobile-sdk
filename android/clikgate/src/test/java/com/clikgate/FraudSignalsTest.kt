package com.clikgate

import android.content.Context
import com.clikgate.internal.Emulator
import com.clikgate.internal.ReferrerData
import com.clikgate.internal.ReferrerOutcome
import com.clikgate.internal.Root
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.atomic.AtomicInteger

/** Fraud signals on `/install` (change 02, B.5.2): heuristics and payload serialisation. */
@RunWith(RobolectricTestRunner::class)
class FraudSignalsTest {
    private lateinit var env: TestEnv

    @Before fun setUp() { env = TestEnv() }

    @After fun tearDown() = env.tearDown()

    // ---------------------------------------------------------------- root heuristics

    private val none: (String) -> Boolean = { false }

    @Test
    fun releaseBuildWithoutSuOrRootAppIsNotRooted() {
        assertFalse(Root.isRooted("release-keys", 34, none, none))
        assertFalse(Root.isRooted(null, 21, none, none))
        assertFalse(Root.isRooted("dev-keys", 29, none, none))
    }

    @Test
    fun testKeysBuildTagsAreRooted() {
        assertTrue(Root.isRooted("test-keys", 34, none, none))
        assertTrue(Root.isRooted("release-keys,test-keys", 34, none, none))
    }

    @Test
    fun suBinaryInACommonPathIsRooted() {
        for (path in listOf("/system/xbin/su", "/sbin/su", "/su/bin/su", "/data/local/xbin/su")) {
            assertTrue(path, Root.isRooted("release-keys", 34, { it == path }, none))
        }
        // A file that merely ends in "su" elsewhere doesn't count.
        assertFalse(Root.isRooted("release-keys", 34, { it == "/system/bin/menu" }, none))
    }

    @Test
    fun rootManagerPackageCountsOnlyBelowApi30() {
        val magisk: (String) -> Boolean = { it == "com.topjohnwu.magisk" }
        assertTrue(Root.isRooted("release-keys", 29, none, magisk))
        assertTrue(Root.isRooted("release-keys", 21, none, { it == "eu.chainfire.supersu" }))

        // API 30+: package visibility filtering hides other apps without <queries>, so the SDK
        // doesn't look them up at all.
        val lookups = AtomicInteger()
        val counting: (String) -> Boolean = { lookups.incrementAndGet(); true }
        assertFalse(Root.isRooted("release-keys", 30, none, counting))
        assertFalse(Root.isRooted("release-keys", 35, none, counting))
        assertEquals(0, lookups.get())
    }

    @Test
    fun liveRootCheckOnTheRobolectricHostDoesNotThrow() {
        // Exercises the real probes (File.exists, PackageManager) without asserting the host's state.
        com.clikgate.internal.DeviceInfo(env.context).isRooted()
    }

    // ---------------------------------------------------------------- emulator heuristics

    @Test
    fun emulatorHeuristicsCoverCommonImagesAndSparePhones() {
        // AOSP / Google emulator images, Genymotion.
        assertTrue(Emulator.isEmulator("google/sdk_gphone64_x86_64/emu64x:15/AE3A/1:user/release-keys", "sdk_gphone64_x86_64", "Google", "google", "emu64x", "sdk_gphone64_x86_64", "ranchu"))
        assertTrue(Emulator.isEmulator("generic_x86/sdk_x86/generic_x86:7.0/NYC/1:user/test-keys", "Android SDK built for x86", "unknown", "generic_x86", "generic_x86", "sdk_x86", "goldfish"))
        assertTrue(Emulator.isEmulator("Genymotion/vbox86p/vbox86p:9/PI/1:user/release-keys", "Samsung Galaxy S9", "Genymotion", "Android", "vbox86p", "vbox86p", "vbox86"))
        // Real phones popular in the target markets.
        assertFalse(Emulator.isEmulator("TECNO/KJ5-OP/TECNO-KJ5:13/TP1A/1:user/release-keys", "TECNO KJ5", "TECNO", "TECNO", "TECNO-KJ5", "KJ5-OP", "mt6768"))
        assertFalse(Emulator.isEmulator("Infinix/X6833B-OP/Infinix-X6833B:13/TP1A/1:user/release-keys", "Infinix X6833B", "INFINIX", "Infinix", "Infinix-X6833B", "X6833B-OP", "mt6789"))
    }

    // ---------------------------------------------------------------- payload

    private fun referrerFrom(fixture: String): ReferrerData {
        val r = Fixtures.json(fixture).getJSONObject("install_referrer")
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

    private fun seedInstallationId(fixture: String) {
        env.context.getSharedPreferences("clikgate.prefs", 0).edit()
            .putString("installation_id", Fixtures.json(fixture).getString("installation_id")).commit()
    }

    private fun sentInstall(): JSONObject {
        eventually { env.api.calls("POST /v1/sdk/install").isNotEmpty() }
        return env.api.body(env.api.calls("POST /v1/sdk/install").first())
    }

    private fun sortKeys(o: JSONObject): JSONObject {
        val out = JSONObject()
        o.keys().asSequence().sorted().forEach { k ->
            val v = o.get(k)
            out.put(k, if (v is JSONObject) sortKeys(v) else v)
        }
        return out
    }

    private class SignalDevice(
        context: Context,
        private val emulator: () -> Boolean,
        private val rooted: () -> Boolean,
    ) : FakeDevice(context) {
        val emulatorChecks = AtomicInteger()
        val rootChecks = AtomicInteger()
        override val deviceModel = "sdk_gphone64_arm64"
        override fun isEmulator(): Boolean { emulatorChecks.incrementAndGet(); return emulator() }
        override fun isRooted(): Boolean { rootChecks.incrementAndGet(); return rooted() }
    }

    @Test
    fun signalsAreSentAndMatchTheContractFixture() {
        val fixture = "install_request_android_signals"
        seedInstallationId(fixture)
        Clikgate.setPushToken("fcm-token-123", PushProvider.FCM)
        env.referrer = FakeReferrerSource(listOf(ReferrerOutcome.Ok(referrerFrom(fixture))))
        val device = SignalDevice(env.context, { true }, { true })
        env.device = device
        env.configure()

        val body = sentInstall()
        assertEquals(sortKeys(Fixtures.json(fixture)).toString(), sortKeys(body).toString())
        SchemaCheck.assertValid("install_request", body)
        // Play's install-begin time is passed through unchanged, earlier than the click here.
        val referrer = body.getJSONObject("install_referrer")
        assertTrue(referrer.getLong("install_begin_timestamp_seconds") < referrer.getLong("referrer_click_timestamp_seconds"))
        // Computed once for the request.
        assertEquals(1, device.emulatorChecks.get())
        assertEquals(1, device.rootChecks.get())
    }

    @Test
    fun aFailingCheckOmitsItsFieldAndTheInstallStillSucceeds() {
        env.device = SignalDevice(env.context, { throw SecurityException("denied") }, { throw IllegalStateException("boom") })
        env.configure()

        val body = sentInstall()
        assertFalse(body.has("is_emulator"))
        assertFalse(body.has("is_rooted"))
        SchemaCheck.assertValid("install_request", body)
        eventually { env.storage.installDone }
    }

    @Test
    fun oneFailingCheckDoesNotDropTheOther() {
        env.device = SignalDevice(env.context, { false }, { throw SecurityException("denied") })
        env.configure()

        val body = sentInstall()
        assertEquals(false, body.getBoolean("is_emulator"))
        assertFalse(body.has("is_rooted"))
    }

    @Test
    fun optedOutInstallSendsNoSignals() {
        env.device = SignalDevice(env.context, { true }, { true })
        Clikgate.setTrackingEnabled(false)
        env.configure()

        val body = sentInstall()
        assertFalse(body.has("is_emulator"))
        assertFalse(body.has("is_rooted"))
    }
}
