package com.clikgate

import com.clikgate.FakeApi.Companion.ok
import com.clikgate.internal.SdkConfig
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** v3 feature switches: `isFeatureEnabled`, fail-fast without network, `feature_disabled` bodies. */
@RunWith(RobolectricTestRunner::class)
class FeatureSwitchesTest {
    private lateinit var env: TestEnv
    private val program = "rpg_01JAB3C4D5E6F7G8H9JKMNPQRS"

    @Before fun setUp() {
        env = TestEnv()
        env.api.on("POST /v1/sdk/referrals/apply-code", ok(Fixtures.text("referral")))
        env.api.on("GET /v1/sdk/referrals/referred-by", ok(Fixtures.text("referred_by_response")))
    }

    @After fun tearDown() = env.tearDown()

    private fun configWith(vararg switches: Pair<String, Boolean>): String {
        val o = Fixtures.json("config_response")
        val f = o.getJSONObject("features")
        for ((k, v) in switches) f.put(k, v)
        return o.toString()
    }

    private fun <T> await(start: (ClikgateCallback<T>) -> Unit): ClikgateResult<T> {
        var result: ClikgateResult<T>? = null
        start { result = it }
        eventually(8_000) { result != null }
        return result!!
    }

    private fun installed() {
        env.configure()
        eventually { env.storage.installDone }
    }

    private fun featureCalls() = env.api.requests.filter {
        val p = it.path!!
        p.startsWith("/v1/sdk/leaderboards") || p.startsWith("/v1/sdk/codes") || p.startsWith("/v1/sdk/referrals")
    }

    @Test
    fun configFixtureMatchesSchemaAndFeatureDisabledFixtureIsRecognised() {
        SchemaCheck.assertValid("config_response", Fixtures.json("config_response"))
        SchemaCheck.assertValid("feature_disabled", Fixtures.json("feature_disabled"))
        assertTrue(com.clikgate.internal.Json.isFeatureDisabled(Fixtures.json("feature_disabled")))
        assertFalse(com.clikgate.internal.Json.isFeatureDisabled(Fixtures.json("referred_by_response")))
        assertFalse(com.clikgate.internal.Json.isFeatureDisabled(JSONObject().put("accepted", true).put("reason", "feature_disabled")))
    }

    @Test
    fun defaultsBeforeConfigure() {
        assertTrue(Clikgate.isFeatureEnabled(ClikgateFeatures.REFERRALS))
        assertTrue(Clikgate.isFeatureEnabled(ClikgateFeatures.LEADERBOARDS))
        assertTrue(Clikgate.isFeatureEnabled(ClikgateFeatures.OFFLINE_CODES))
        assertTrue(Clikgate.isFeatureEnabled(ClikgateFeatures.APP_ATTRIBUTION))
        assertFalse(Clikgate.isFeatureEnabled(ClikgateFeatures.IDENTITY_CHECKS))
        assertFalse(Clikgate.isFeatureEnabled(ClikgateFeatures.WHATSAPP_ATTRIBUTION))
        assertFalse(Clikgate.isFeatureEnabled(ClikgateFeatures.SKAN_POSTBACKS))
        assertFalse(Clikgate.isFeatureEnabled("no_such_feature"))
    }

    @Test
    fun valuesComeFromTheFetchedConfig() {
        env.api.on("GET /v1/sdk/config", ok(configWith("leaderboards" to false, "identity_checks" to true)))
        installed()
        assertFalse(Clikgate.isFeatureEnabled("leaderboards"))
        assertTrue(Clikgate.isFeatureEnabled("identity_checks"))
        assertTrue(Clikgate.isFeatureEnabled("uninstall_tracking"))
        assertFalse(Clikgate.isFeatureEnabled("probabilistic_matching"))
        assertFalse(Clikgate.isFeatureEnabled("pasteboard_matching")) // not a boolean switch
        assertFalse(Clikgate.isFeatureEnabled("unknown"))
    }

    @Test
    fun olderServerWithoutV3KeysUsesCatalogueDefaults() {
        val o = Fixtures.json("config_response")
        val f = o.getJSONObject("features")
        listOf("app_attribution", "referrals", "leaderboards", "identity_checks", "whatsapp_attribution", "offline_codes", "skan_postbacks").forEach { f.remove(it) }
        val c = SdkConfig.parse(o)
        assertTrue(c.isFeatureEnabled("referrals"))
        assertTrue(c.isFeatureEnabled("leaderboards"))
        assertTrue(c.isFeatureEnabled("offline_codes"))
        assertTrue(c.isFeatureEnabled("app_attribution"))
        assertFalse(c.isFeatureEnabled("identity_checks"))
        assertFalse(c.isFeatureEnabled("whatsapp_attribution"))
    }

    @Test
    fun cachedConfigIsUsedRightAfterRelaunch() {
        env.api.on("GET /v1/sdk/config", ok(configWith("offline_codes" to false)))
        installed()
        // The relaunch reads the cache synchronously, before anything is fetched.
        Clikgate.resetForTesting()
        env.configure()
        assertFalse(Clikgate.isFeatureEnabled("offline_codes"))
    }

    @Test
    fun switchedOffFeaturesFailFastWithoutNetwork() {
        env.api.on("GET /v1/sdk/config", ok(configWith("referrals" to false)))
        installed()
        val errors = listOf(
            await<Referral> { Clikgate.referrals.applyCode(program, "ADA42", it) }.errorOrNull()!!,
            await<ReferredBy> { Clikgate.referrals.referredBy(it) }.errorOrNull()!!,
        )
        for (err in errors) {
            assertEquals(ClikgateError.FEATURE_DISABLED, err.code)
            assertEquals("referrals", err.feature)
            assertEquals(null, err.status)
        }
        settle()
        assertEquals(emptyList<String>(), featureCalls().map { it.path })
    }

    @Test
    fun cachedSwitchFailsFastEvenBeforeInstall() {
        env.api.on("GET /v1/sdk/config", ok(configWith("referrals" to false)))
        installed()
        Clikgate.resetForTesting()
        env.api.requests.clear()
        env.configure()
        val err = await<ReferredBy> { Clikgate.referrals.referredBy(it) }.errorOrNull()!!
        assertEquals(ClikgateError.FEATURE_DISABLED, err.code)
        assertTrue(featureCalls().isEmpty())
    }

    @Test
    fun serverNoOpBodyMapsToFeatureDisabledAndRefreshesConfig() {
        installed()
        assertTrue(Clikgate.isFeatureEnabled("referrals"))
        val configCalls = env.api.calls("GET /v1/sdk/config").size
        // The server switched the feature off since the config was cached.
        env.api.on("GET /v1/sdk/referrals/referred-by", ok("""{"accepted":false,"reason":"feature_disabled","feature":"referrals","extra":1}"""))
        env.api.on("GET /v1/sdk/config", ok(configWith("referrals" to false)))
        val err = await<ReferredBy> { Clikgate.referrals.referredBy(it) }.errorOrNull()!!
        assertEquals(ClikgateError.FEATURE_DISABLED, err.code)
        assertEquals("referrals", err.feature)
        assertFalse(Clikgate.isFeatureEnabled("referrals"))
        eventually(message = "config refresh") { env.api.calls("GET /v1/sdk/config").size == configCalls + 1 }
        // Next call: no network.
        val before = featureCalls().size
        assertEquals(ClikgateError.FEATURE_DISABLED, await<Referral> { Clikgate.referrals.applyCode(program, "ADA42", it) }.errorOrNull()!!.code)
        assertEquals(before, featureCalls().size)
    }

    @Test
    fun freshConfigTurnsAFeatureBackOn() {
        installed()
        env.api.on("GET /v1/sdk/referrals/referred-by", ok(Fixtures.text("feature_disabled")), ok(Fixtures.text("referred_by_response")))
        // The refreshed config says the feature is on again (e.g. re-enabled meanwhile).
        val configCalls = env.api.calls("GET /v1/sdk/config").size
        assertEquals(ClikgateError.FEATURE_DISABLED, await<ReferredBy> { Clikgate.referrals.referredBy(it) }.errorOrNull()!!.code)
        eventually { env.api.calls("GET /v1/sdk/config").size == configCalls + 1 && Clikgate.isFeatureEnabled("referrals") }
        assertTrue(await<ReferredBy> { Clikgate.referrals.referredBy(it) }.getOrThrow().referred)
    }
}
