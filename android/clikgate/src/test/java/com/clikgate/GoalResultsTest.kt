package com.clikgate

import com.clikgate.FakeApi.Companion.errorCode
import com.clikgate.FakeApi.Companion.ok
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.shadows.ShadowLog
import java.math.BigDecimal
import java.util.concurrent.ConcurrentHashMap

/** One goal() method: provider on the wire, GoalResult from the server's results, Provider, test-mode lines. */
@RunWith(RobolectricTestRunner::class)
class GoalResultsTest {
    private lateinit var env: TestEnv
    private val results = ConcurrentHashMap<String, GoalResult>()

    @Before fun setUp() {
        env = TestEnv()
        ShadowLog.clear()
    }

    @After fun tearDown() = env.tearDown()

    private fun installed(sdkKey: String = "cg_sdk_test", level: LogLevel = LogLevel.NONE) {
        env.configure(env.options().copy(logLevel = level), sdkKey = sdkKey)
        eventually { env.storage.installDone }
        eventually { env.core().isIdleForTests() }
    }

    private fun collect(name: String) = GoalResultListener { results[name] = it }

    private fun sentGoals(): List<JSONObject> = env.api.calls("POST /v1/sdk/goals").flatMap { r ->
        val a = env.api.body(r).getJSONArray("goals")
        (0 until a.length()).map { a.getJSONObject(it) }
    }

    private fun logs() = ShadowLog.getLogsForTag("Clikgate").map { it.msg }

    @Test
    fun resultsAreMatchedByIndex() {
        env.api.on("POST /v1/sdk/goals", ok(Fixtures.text("goals_response_results")))
        installed()
        Clikgate.goal("account_opened", reference = "APP-1", onResult = collect("a"))
        Clikgate.goal("purchase", value = BigDecimal("10"), reference = "T123456", provider = Provider.PAYSTACK, onResult = collect("p"))
        Clikgate.goal("order_paid", reference = "ORD-1", onResult = collect("o"))
        assertTrue(env.core().flushBlocking(3_000))
        eventually { results.size == 3 }
        assertEquals(GoalResult(GoalStatus.COUNTED, null, GoalKind.STANDARD, false), results["a"])
        assertEquals(GoalResult(GoalStatus.WAITING, "waiting_for_confirmation", GoalKind.PAYMENT, true), results["p"])
        assertEquals(GoalResult(GoalStatus.REFUSED, "payment_goal_needs_confirmation", GoalKind.PAYMENT, false), results["o"])
        assertEquals(0, env.queue.count())
    }

    @Test
    fun providerGoesOnTheGoalItemAndThereIsNoPaymentsCall() {
        installed()
        Clikgate.goal("purchase", reference = "T123456", provider = Provider.PAYSTACK)
        Clikgate.goal("account_opened", reference = "APP-1")
        assertTrue(env.core().flushBlocking(3_000))
        val sent = sentGoals()
        val fixture = Fixtures.json("goals_request_payment").getJSONArray("goals")
        for (i in 0..1) {
            val want = fixture.getJSONObject(i)
            assertEquals(want.keys().asSequence().toSet() - "click_id", sent[i].keys().asSequence().toSet() - "click_id")
        }
        assertEquals("paystack", sent[0].getString("provider"))
        assertFalse(sent[0].has("value"))
        assertFalse(sent[1].has("provider"))
        assertFalse(sent[0].has("kind"))
        SchemaCheck.assertValid("goals_request", env.api.body(env.api.calls("POST /v1/sdk/goals").single()))
        assertTrue(env.api.requests.none { it.path!!.contains("payments") })
    }

    @OptIn(ClikgateInternalApi::class)
    @Test
    fun wrapperProviderStrings() {
        installed()
        assertNull(Clikgate.goalFromWrapper("purchase", null, null, "T1", " Flutterwave ", null, null))
        assertNull(Clikgate.goalFromWrapper("purchase", null, null, "T2", "newpay", null, null)) // added after this release
        assertTrue(env.core().flushBlocking(3_000))
        assertEquals(listOf("flutterwave", "newpay"), sentGoals().map { it.getString("provider") })
        Clikgate.goalFromWrapper("purchase", null, null, "T3", "bad provider", null, collect("bad"))
        eventually { results.containsKey("bad") }
        assertEquals(GoalResult(GoalStatus.REFUSED, ClikgateError.INVALID_ARGUMENT, null, false), results["bad"])
    }

    @Test
    fun providerFromString() {
        assertSame(Provider.PAYSTACK, Provider.fromString("paystack"))
        assertSame(Provider.MTN_MOMO, Provider.fromString("  MTN_MOMO "))
        assertEquals("newpay", Provider.fromString("newpay")?.value)
        assertEquals(Provider.fromString("newpay"), Provider.fromString("NewPay"))
        assertNull(Provider.fromString(""))
        assertNull(Provider.fromString("pay stack"))
        assertNull(Provider.fromString("9pay"))
        assertNull(Provider.fromString("a".repeat(31)))
        assertEquals("checkout_com", Provider.CHECKOUT_COM.toString())
        // The generated constants are exactly the committed provider list.
        val snapshot = JSONObject(javaClass.classLoader!!.getResource("providers.json")!!.readText()).getJSONArray("providers")
        assertEquals((0 until snapshot.length()).map { snapshot.getString(it) }, Provider.entries.map { it.value })
    }

    @Test
    fun localRefusals() {
        installed()
        Clikgate.goal("Bad Key", onResult = collect("invalid"))
        Clikgate.goal("purchase", reference = "", onResult = collect("ref"))
        eventually { results.size == 2 }
        assertEquals(GoalResult(GoalStatus.REFUSED, "invalid_argument", null, false), results["invalid"])
        assertEquals("invalid_argument", results["ref"]?.reason)

        Clikgate.setTrackingEnabled(false)
        Clikgate.goal("purchase", reference = "T1", onResult = collect("off"))
        eventually { results.containsKey("off") }
        assertEquals("opted_out", results["off"]?.reason)
        assertTrue(env.api.calls("POST /v1/sdk/goals").isEmpty())
    }

    @Test
    fun optOutRefusesQueuedGoals() {
        env.api.on("POST /v1/sdk/goals", errorCode(503, "server_error"))
        installed()
        Clikgate.goal("purchase", reference = "T1", onResult = collect("q"))
        eventually { env.queue.count() == 1 }
        Clikgate.setTrackingEnabled(false)
        eventually { results.containsKey("q") }
        assertEquals(GoalResult(GoalStatus.REFUSED, "opted_out", null, false), results["q"])
    }

    @Test
    fun olderServerRejected422AndDuplicateListeners() {
        env.api.on("POST /v1/sdk/goals", ok(Fixtures.text("goals_response_rejected")))
        installed()
        Clikgate.goal("kyc_passed", reference = "0b7e4c1a-2f3d-4e5a-9b8c-7d6e5f4a3b2c", onResult = collect("rej"))
        Clikgate.goal("account_opened", reference = "APP-9", onResult = collect("ok"))
        Clikgate.goal("account_opened", reference = "APP-9", onResult = collect("ok2")) // already queued: same result
        assertTrue(env.core().flushBlocking(3_000))
        eventually { results.size == 3 }
        assertEquals(GoalResult(GoalStatus.REFUSED, "goal_not_found", null, false), results["rej"])
        assertEquals(GoalResult(GoalStatus.COUNTED, null, null, false), results["ok"])
        assertEquals(results["ok"], results["ok2"])
        assertEquals(2, sentGoals().size)

        env.api.on("POST /v1/sdk/goals", errorCode(422, "validation_error"))
        Clikgate.goal("kyc_passed", reference = "K2", onResult = collect("422"))
        assertTrue(env.core().flushBlocking(3_000))
        eventually { results.containsKey("422") }
        assertEquals("validation_error", results["422"]?.reason)
    }

    @Test
    fun retriesKeepTheListenerUntilTheAnswer() {
        env.api.on("POST /v1/sdk/goals", errorCode(503, "server_error"), ok(Fixtures.text("goals_response_results")))
        installed()
        Clikgate.goal("account_opened", reference = "APP-1", onResult = collect("a"))
        assertTrue(env.core().flushBlocking(5_000))
        eventually { results.containsKey("a") }
        assertEquals(GoalStatus.COUNTED, results["a"]?.status)
    }

    @Test
    fun testKeysLogOneLineForWaitingAndIgnoredValues() {
        env.api.on("POST /v1/sdk/goals", ok(Fixtures.text("goals_response_results")))
        installed(sdkKey = "cg_sdk_test_" + "a".repeat(32), level = LogLevel.WARN)
        Clikgate.goal("account_opened", reference = "APP-1")
        Clikgate.goal("purchase", value = BigDecimal("10"), reference = "T123456", provider = Provider.PAYSTACK)
        assertTrue(env.core().flushBlocking(3_000))
        eventually { logs().any { "waiting for confirmation" in it } }
        assertEquals(listOf("purchase is a Payment goal: waiting for confirmation"), logs().filter { "waiting for confirmation" in it })
        assertEquals(
            listOf("purchase is a Payment goal: the value was ignored (the amount comes from the confirmation)"),
            logs().filter { "value was ignored" in it },
        )
        assertTrue(logs().none { "T123456" in it || "APP-1" in it }) // never the reference
    }

    @Test
    fun liveKeysDontLogTheTestModeLines() {
        env.api.on("POST /v1/sdk/goals", ok(Fixtures.text("goals_response_results")))
        installed(sdkKey = "cg_sdk_live_" + "a".repeat(32), level = LogLevel.WARN)
        Clikgate.goal("account_opened", reference = "APP-1")
        Clikgate.goal("purchase", value = BigDecimal("10"), reference = "T123456", provider = Provider.PAYSTACK, onResult = collect("p"))
        assertTrue(env.core().flushBlocking(3_000))
        eventually { results.containsKey("p") }
        assertTrue(logs().none { "Payment goal" in it })
    }
}
