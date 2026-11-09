package com.clikgate

import com.clikgate.FakeApi.Companion.ok
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.shadows.ShadowLog
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Change 10 (D.5, contract B3a.2): deep links on, attribution off (an app with
 * attribution switched off). goal() warns once ("switched off") and does nothing; the
 * server's `feature_disabled` answer on /goals is never retried; the "no deferred link"
 * install result at the monthly cap is a normal empty result.
 */
@OptIn(ClikgateInternalApi::class)
@RunWith(RobolectricTestRunner::class)
class DeepLinkOnlyTest {
    private lateinit var env: TestEnv

    @Before fun setUp() {
        env = TestEnv()
        ShadowLog.clear()
    }

    @After fun tearDown() = env.tearDown()

    private fun warnings() = ShadowLog.getLogsForTag("Clikgate").map { it.msg }.filter { "app attribution is switched off" in it }

    private fun installed() {
        env.configure(env.options().copy(logLevel = LogLevel.WARN))
        eventually { env.storage.installDone }
        eventually { env.core().isIdleForTests() }
    }

    @Test
    fun configWithAttributionOffSkipsGoalsWithOneWarning() {
        env.api.on("GET /v1/sdk/config", ok(Fixtures.text("config_response_deep_link_only")))
        installed()
        eventually { !Clikgate.isFeatureEnabled(ClikgateFeatures.APP_ATTRIBUTION) }
        assertTrue(Clikgate.isFeatureEnabled("deep_linking"))

        val results = java.util.concurrent.CopyOnWriteArrayList<GoalResult>()
        Clikgate.goal("account_opened", reference = "APP-1") { results.add(it) }
        assertNull(Clikgate.goalFromWrapper("order_paid", "1500.50", "NGN", "ORD-1", null, null, null))
        Clikgate.goal("signup")
        assertTrue(env.core().flushBlocking(3_000))

        assertEquals(0, env.queue.count())
        assertTrue(env.api.calls("POST /v1/sdk/goals").isEmpty())
        assertEquals(1, warnings().size)
        eventually { results.size == 1 }
        assertEquals(GoalResult(GoalStatus.REFUSED, "feature_disabled", null, false), results.single())
    }

    @Test
    fun featureDisabledOnGoalsIsDroppedNotRetried() {
        env.api.on(
            "GET /v1/sdk/config",
            ok(Fixtures.text("config_response")),
            ok(Fixtures.text("config_response_deep_link_only")),
        )
        env.api.on("POST /v1/sdk/goals", ok(Fixtures.text("goals_response_feature_disabled")))
        installed()
        val results = java.util.concurrent.CopyOnWriteArrayList<GoalResult>()
        Clikgate.goal("account_opened", reference = "APP-1") { results.add(it) }
        assertTrue(env.core().flushBlocking(3_000))
        eventually { results.size == 1 }
        assertEquals(GoalStatus.REFUSED, results.single().status)
        assertEquals("feature_disabled", results.single().reason)
        assertEquals(0, env.queue.count())
        assertEquals(1, env.api.calls("POST /v1/sdk/goals").size)
        eventually { !Clikgate.isFeatureEnabled(ClikgateFeatures.APP_ATTRIBUTION) }
        assertEquals(1, warnings().size)

        // Later calls stop on the device: no second /goals call, no second warning.
        Clikgate.goal("order_paid")
        assertTrue(env.core().flushBlocking(3_000))
        assertEquals(1, env.api.calls("POST /v1/sdk/goals").size)
        assertEquals(1, warnings().size)
    }

    @Test
    fun deferredDeepLinkIsDeliveredWithOrganicAttribution() {
        env.api.on("GET /v1/sdk/config", ok(Fixtures.text("config_response_deep_link_only")))
        env.api.on("POST /v1/sdk/install", ok(Fixtures.text("install_response_deep_link_only")))
        val links = CopyOnWriteArrayList<ClikgateDeepLink>()
        env.configure(env.options("yourapp.clk.ng"))
        eventually { env.storage.installDone }
        Clikgate.onDeepLink { links.add(it) }
        eventually { links.size == 1 }
        assertEquals("/products/42", links.first().path)
        assertTrue(links.first().isDeferred)
        val attribution = runBlocking { Clikgate.awaitAttributionForTest() }
        assertEquals("organic", attribution.status)
        assertNull(attribution.link)
    }

    @Test
    fun noDeferredLinkAtTheCapIsANormalEmptyResult() {
        env.api.on("GET /v1/sdk/config", ok(Fixtures.text("config_response_deep_link_only")))
        env.api.on("POST /v1/sdk/install", ok(Fixtures.text("install_response_deferred_cap")))
        val links = CopyOnWriteArrayList<ClikgateDeepLink>()
        installed()
        Clikgate.onDeepLink { links.add(it) }
        settle(200)
        assertTrue(links.isEmpty())
        assertEquals(1, env.api.calls("POST /v1/sdk/install").size) // no retry
        val attribution = runBlocking { Clikgate.awaitAttributionForTest() }
        assertEquals("organic", attribution.status)
    }
}
