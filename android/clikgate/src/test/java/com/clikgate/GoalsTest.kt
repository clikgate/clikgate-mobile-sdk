package com.clikgate

import com.clikgate.FakeApi.Companion.errorCode
import com.clikgate.FakeApi.Companion.ok
import com.clikgate.internal.Goals
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
import java.math.BigDecimal

/** goal(): decimal values, the shared queue and private mode. */
@RunWith(RobolectricTestRunner::class)
class GoalsTest {
    private lateinit var env: TestEnv

    @Before fun setUp() { env = TestEnv() }

    @After fun tearDown() = env.tearDown()

    private fun config(name: String, edit: JSONObject.() -> Unit = {}) =
        env.api.on("GET /v1/sdk/config", ok(Fixtures.json(name).apply(edit).toString()))

    private fun installed() {
        env.configure()
        eventually { env.storage.installDone }
        eventually { env.core().isIdleForTests() }
    }

    private fun sentGoals(): List<JSONObject> = env.api.calls("POST /v1/sdk/goals").flatMap { r ->
        val a = env.api.body(r).getJSONArray("goals")
        (0 until a.length()).map { a.getJSONObject(it) }
    }

    private fun err(block: () -> Unit): ClikgateError = try {
        block(); throw AssertionError("expected error")
    } catch (e: ClikgateError) { e }

    // ------------------------------------------------------------------ values and validation

    @Test
    fun decimalWireValuesRoundTrip() {
        val cases = mapOf(
            "2000000" to "2000000",
            "2E+6" to "2000000",
            "1500.50" to "1500.5",
            "0.10" to "0.1",
            "0" to "0",
            "0.00" to "0",
            "0.005" to "0.005",
            "999999999999999" to "999999999999999", // 15 digits
            "1234567890123.45" to "1234567890123.45", // 15 digits
            "12345678901234500000" to "12345678901234500000", // trailing integer zeros count
        )
        for ((input, wire) in cases) {
            if (Goals.significantDigits(wire) > 15) {
                assertEquals(input, "value", err { Goals.wireValue(BigDecimal(input)) }.param)
                continue
            }
            val out = Goals.wireValue(BigDecimal(input))
            assertEquals(input, wire, out)
            // Parsing the wire string gives the same decimal back (no floating point anywhere).
            assertEquals(input, 0, BigDecimal(out).compareTo(BigDecimal(input)))
            assertTrue(out.matches(Regex(SchemaCheck.schema("goals_request").getJSONObject("properties").getJSONObject("goals")
                .getJSONObject("items").getJSONObject("properties").getJSONObject("value").getJSONArray("anyOf").getJSONObject(0).getString("pattern"))))
        }
        assertEquals(1, Goals.significantDigits("0.005"))
        assertEquals(7, Goals.significantDigits("2000000"))
        assertEquals("value", err { Goals.wireValue(BigDecimal("-1")) }.param)
        assertEquals("value", err { Goals.wireValue(BigDecimal("1234567890123456")) }.param) // 16 digits
        assertEquals("value", err { Goals.wireValue(BigDecimal("0.1234567890123456")) }.param)
        // Wrapper strings
        assertEquals(0, Goals.parseValue("1500.50")!!.compareTo(BigDecimal("1500.5")))
        assertNull(Goals.parseValue("1e5"))
        assertNull(Goals.parseValue("abc"))
        assertNull(Goals.parseValue(""))
        assertNotNull(Goals.parseValue("-3")) // parsed, then rejected as negative
    }

    @Test
    fun localValidation() {
        fun build(key: String, value: BigDecimal? = null, currency: String? = null, reference: String? = null) =
            Goals.build(key, value, currency, reference, null, null, null, 0)
        for (bad in listOf("a", "Account", "1abc", "account-opened", "account opened", "a".repeat(41), "", "_x")) {
            assertEquals(bad, "goal", err { build(bad) }.param)
        }
        build("ab"); build("a".repeat(40)); build("account_opened_2")
        assertEquals("value", err { build("order_paid", value = BigDecimal("-0.01")) }.param)
        assertEquals("currency", err { build("order_paid", value = BigDecimal.ONE, currency = "ngn") }.param)
        assertEquals("reference", err { build("order_paid", reference = "") }.param)
        assertEquals("reference", err { build("order_paid", reference = "   ") }.param)
        assertEquals("reference", err { build("order_paid", reference = "x".repeat(129)) }.param)
        assertEquals(ClikgateError.INVALID_ARGUMENT, err { build("A") }.code)
    }

    @Test
    fun itemMatchesContractAndFixture() {
        val fixture = Fixtures.json("goals_request").getJSONArray("goals").getJSONObject(0)
        val o = Goals.build(
            "account_opened",
            BigDecimal("2000000"), "NGN", "APP-55231", null, true,
            fixture.getString("click_id"),
            1_792_746_720_000L, // 2026-10-23T09:12:00Z
        )
        fixture.keys().forEach { k -> assertEquals(k, fixture.get(k).toString(), o.get(k).toString()) }
        assertEquals(fixture.keys().asSequence().toSet(), o.keys().asSequence().toSet())
        // Without options: generated UUID reference, no value / currency / is_first / click.
        val bare = Goals.build("kyc_passed", null, null, null, null, null, null, 0)
        assertTrue(bare.getString("reference").matches(Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")))
        assertEquals(setOf("goal", "reference", "occurred_at"), bare.keys().asSequence().toSet())
        SchemaCheck.assertValid("goals_request", JSONObject().put("goals", org.json.JSONArray().put(o).put(bare)))
    }

    @OptIn(ClikgateInternalApi::class)
    @Test
    fun validationErrorsReachTheWrappersAndNothingIsQueued() {
        installed()
        assertEquals("goal", Clikgate.goalFromWrapper("Bad", null, null, null, null, null, null)?.param)
        assertEquals("value", Clikgate.goalFromWrapper("order_paid", "12.3e4", null, null, null, null, null)?.param)
        assertEquals("value", Clikgate.goalFromWrapper("order_paid", "-5", null, null, null, null, null)?.param)
        assertEquals("provider", Clikgate.goalFromWrapper("order_paid", null, null, "T1", "Pay Stack!", null, null)?.param)
        assertNull(Clikgate.goalFromWrapper("order_paid", "1500.50", "USD", "ORD-1", null, false, null))
        env.core().flushBlocking(3_000)
        val g = sentGoals().single()
        assertEquals("1500.5", g.getString("value"))
        assertEquals("USD", g.getString("currency"))
        assertFalse(g.getBoolean("is_first"))
    }

    // ------------------------------------------------------------------ delivery

    @Test
    fun goalIsQueuedSentWithConsentAndMatchesTheSchema() {
        installed()
        Clikgate.goal("account_opened", value = BigDecimal("2000000"), currency = "NGN", reference = "APP-55231", isFirst = true)
        assertTrue(env.core().flushBlocking(3_000))
        val req = env.api.calls("POST /v1/sdk/goals").single()
        val body = env.api.body(req)
        SchemaCheck.assertValid("goals_request", body)
        assertNotNull(body.getJSONObject("consent"))
        assertNotNull(req.getHeader("Idempotency-Key"))
        assertNotNull(req.getHeader("Clikgate-Installation-Id"))
        val g = body.getJSONArray("goals").getJSONObject(0)
        assertEquals("2000000", g.getString("value"))
        assertEquals("APP-55231", g.getString("reference"))
        assertEquals(0, env.queue.count())
    }

    @Test
    fun clickIdOfTheInstallIsAttached() {
        env.api.on("POST /v1/sdk/install", ok(Fixtures.text("install_response_referral")))
        installed()
        Clikgate.goal("signup_done")
        env.core().flushBlocking(3_000)
        assertEquals("clk_01JAB3C4D5E6F7G8H9JKMNPQRS", sentGoals().single().getString("click_id"))
    }

    @Test
    fun goalsKeepTheirOrder() {
        installed()
        Clikgate.goal("g_one", reference = "R1")
        Clikgate.goal("g_two", reference = "R2")
        assertTrue(env.core().flushBlocking(5_000))
        assertEquals(listOf("R1", "R2"), sentGoals().map { it.getString("reference") })
    }

    @Test
    fun sameReferenceIsIdempotentAndRetriesKeepTheItem() {
        env.api.on("POST /v1/sdk/goals", errorCode(503, "server_error"), errorCode(503, "server_error"), ok(Fixtures.text("goals_response")))
        installed()
        Clikgate.goal("order_paid", value = BigDecimal("10"), reference = "ORD-9")
        Clikgate.goal("order_paid", value = BigDecimal("10"), reference = "ORD-9") // ignored: already queued
        Clikgate.goal("order_paid", value = BigDecimal("10"), reference = "ORD-10")
        assertTrue(env.core().flushBlocking(5_000)) // two 503s, then success (send's retry policy)
        eventually { env.api.calls("POST /v1/sdk/goals").size == 3 }
        eventually { env.queue.count() == 0 }
        val bodies = env.api.calls("POST /v1/sdk/goals").map { env.api.body(it).getJSONArray("goals").toString() }
        assertEquals(1, bodies.toSet().size) // the same items on every retry (references, times)
        assertEquals(2, env.api.body(env.api.calls("POST /v1/sdk/goals").last()).getJSONArray("goals").length())
        // Change 09 (X.E15): one random Idempotency-Key per call, reused by its retries, never a hash of the reference.
        val keys = env.api.calls("POST /v1/sdk/goals").map { it.getHeader("Idempotency-Key") }
        assertEquals(1, keys.toSet().size)
        assertTrue(keys.first()!!.matches(Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")))
    }

    @Test
    fun eachGoalCallGetsItsOwnIdempotencyKey() {
        installed()
        Clikgate.goal("order_paid", reference = "ORD-1")
        assertTrue(env.core().flushBlocking(3_000))
        Clikgate.goal("order_paid", reference = "ORD-2")
        assertTrue(env.core().flushBlocking(3_000))
        val keys = env.api.calls("POST /v1/sdk/goals").map { it.getHeader("Idempotency-Key") }
        assertEquals(2, keys.size)
        assertEquals(2, keys.toSet().size)
    }

    @Test
    fun goalsSurviveARelaunchUntilSent() {
        env.api.on("POST /v1/sdk/goals", MockResponse().setResponseCode(500))
        installed()
        Clikgate.goal("loan_disbursed", value = BigDecimal("150000.75"), reference = "LN-1")
        assertFalse(env.core().flushBlocking(3_000))
        assertEquals(1, env.queue.count())
        env.api.on("POST /v1/sdk/goals", ok(Fixtures.text("goals_response")))
        env.relaunch()
        eventually { env.queue.count() == 0 }
        val last = env.api.body(env.api.calls("POST /v1/sdk/goals").last()).getJSONArray("goals").getJSONObject(0)
        assertEquals("150000.75", last.getString("value"))
        assertEquals("LN-1", last.getString("reference"))
    }

    @Test
    fun rejectedItemsAnd422AndOldServers404AreDropped() {
        env.api.on("POST /v1/sdk/goals", ok(Fixtures.text("goals_response_rejected")))
        installed()
        Clikgate.goal("kyc_passed")
        assertTrue(env.core().flushBlocking(3_000))
        assertEquals(0, env.queue.count())

        env.api.on("POST /v1/sdk/goals", errorCode(422, "validation_error"))
        Clikgate.goal("kyc_passed")
        assertTrue(env.core().flushBlocking(3_000))
        assertEquals(0, env.queue.count())

        env.api.on("POST /v1/sdk/goals", errorCode(404, "not_found"))
        Clikgate.goal("kyc_passed")
        assertTrue(env.core().flushBlocking(3_000))
        assertEquals(0, env.queue.count()) // the queue isn't blocked
    }

    @Test
    fun goalsBeforeInstallWaitInTheQueue() {
        env.api.on("POST /v1/sdk/install", MockResponse().setResponseCode(500))
        Clikgate.goal("early_goal", reference = "E1") // before configure, too
        env.configure()
        settle(400)
        assertTrue(env.api.calls("POST /v1/sdk/goals").isEmpty())
        assertEquals(1, env.queue.count())
    }

    // ------------------------------------------------------------------ consent (change 03)

    @Test
    fun goalsAreBufferedForConsentAndSentAfterGrant() {
        config("config_response_consent_required")
        env.configure()
        eventually { env.api.calls("GET /v1/sdk/config").isNotEmpty() }
        Clikgate.goal("account_opened", reference = "APP-1")
        eventually { env.queue.count() == 1 }
        settle(300)
        assertTrue(env.api.calls("POST /v1/sdk/goals").isEmpty())
        Clikgate.setConsent(attribution = ConsentState.GRANTED)
        eventually { env.api.calls("POST /v1/sdk/goals").isNotEmpty() }
        assertEquals("granted", env.api.body(env.api.calls("POST /v1/sdk/goals").single()).getJSONObject("consent").getString("attribution"))
    }

    @Test
    fun deniedConsentDropsGoals() {
        config("config_response_consent_required")
        env.configure()
        eventually { env.api.calls("GET /v1/sdk/config").isNotEmpty() }
        Clikgate.goal("account_opened", reference = "APP-1")
        eventually { env.queue.count() == 1 }
        Clikgate.setConsent(attribution = ConsentState.DENIED)
        eventually { env.queue.count() == 0 }
        Clikgate.goal("account_opened", reference = "APP-2")
        settle(300)
        assertEquals(0, env.queue.count())
        assertTrue(env.api.calls("POST /v1/sdk/goals").isEmpty())
    }

    // ------------------------------------------------------------------ private mode

    @Test
    fun configWithoutPrivateModeMeansOff() {
        assertFalse(com.clikgate.internal.SdkConfig.parse(Fixtures.json("config_response")).privateMode)
        assertFalse(com.clikgate.internal.SdkConfig.parse(Fixtures.json("config_response_legacy")).privateMode)
        assertTrue(com.clikgate.internal.SdkConfig.parse(Fixtures.json("config_response_private_mode")).privateMode)
        installed()
        Clikgate.identifyUser(customerId = "user_42")
        eventually { env.api.calls("POST /v1/sdk/identify").isNotEmpty() }
        assertEquals("user_42", env.api.body(env.api.calls("POST /v1/sdk/identify").single()).getString("customer_user_id"))
    }

    @Test
    fun privateModeDropsIdentifyButNotGoals() {
        config("config_response_private_mode")
        installed()
        Clikgate.identifyUser(customerId = "user_42", identityToken = "tok")
        Clikgate.goal("order_paid", value = BigDecimal("15"), currency = "NGN", reference = "ORD-1")
        assertTrue(env.core().flushBlocking(5_000))
        settle(300)
        assertTrue(env.api.calls("POST /v1/sdk/identify").isEmpty())
        assertNull(env.storage.customerUserId)
        val g = sentGoals().single()
        assertEquals("15", g.getString("value"))
        assertEquals("ORD-1", g.getString("reference"))
    }

    @Test
    fun privateModeDiscardsAnIdentifyQueuedBeforeTheConfigArrived() {
        // An identify stored on a launch before private mode was turned on, still unsent.
        env.storage.customerUserId = "user_42"
        env.storage.identifyPending = true
        config("config_response_private_mode")
        installed()
        settle(300)
        assertTrue(env.api.calls("POST /v1/sdk/identify").isEmpty())
        assertFalse(env.storage.identifyPending)
        assertNull(env.storage.customerUserId)
    }

    // ------------------------------------------------------------ Change 14: labels

    @Test
    fun goalCarriesALabel() {
        installed()
        Clikgate.goal("account_opened", reference = "APP-1", isFirst = true, label = " Ada ")
        assertTrue(env.core().flushBlocking(5_000))
        val g = sentGoals().single()
        assertEquals("Ada", g.getString("label"))
        assertTrue(g.getBoolean("is_first"))
    }

    @Test
    fun privateModeKeepsOnlyTheLabelWhenLabelsAreAllowed() {
        config("config_response_private_mode_labels")
        installed()
        Clikgate.identifyUser(label = "Ada", customerId = "user_42", identityToken = "tok")
        eventually { env.api.calls("POST /v1/sdk/identify").size == 1 }
        val body = env.api.body(env.api.calls("POST /v1/sdk/identify")[0])
        assertFalse(body.has("customer_user_id") || body.has("identity_token"))
        assertEquals("Ada", body.getString("label"))
        assertNull(env.storage.customerUserId)
    }

    @Test
    fun privateModeDropsLabelsWithoutTheSwitch() {
        config("config_response_private_mode")
        installed()
        Clikgate.identifyUser(label = "Ada")
        Clikgate.goal("order_paid", reference = "ORD-2", label = "Ada")
        assertTrue(env.core().flushBlocking(5_000))
        settle(300)
        assertTrue(env.api.calls("POST /v1/sdk/identify").isEmpty())
        assertFalse(sentGoals().single().has("label"))
    }
}

