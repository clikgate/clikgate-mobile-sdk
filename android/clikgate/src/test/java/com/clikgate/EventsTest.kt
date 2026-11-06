package com.clikgate

import com.clikgate.FakeApi.Companion.errorCode
import com.clikgate.FakeApi.Companion.ok
import com.clikgate.internal.Core
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.SocketPolicy
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

@RunWith(RobolectricTestRunner::class)
class EventsTest {
    private lateinit var env: TestEnv

    @Before fun setUp() { env = TestEnv() }

    @After fun tearDown() = env.tearDown()

    private fun installed() {
        env.configure()
        eventually { env.storage.installDone }
        eventually { env.core().isIdleForTests() }
    }

    private fun sentEvents(): List<JSONObject> = env.api.calls("POST /v1/sdk/events").flatMap { r ->
        val a = env.api.body(r).getJSONArray("events")
        (0 until a.length()).map { a.getJSONObject(it) }
    }

    @Test
    fun eventPayloadMatchesContract() {
        val o = Core.buildEvent("purchase", ClikgateMoney.ofMinor(1_500_000, "NGN"), mapOf("order_id" to "A-1001"), false, 1_760_954_561_123L)
        val fixture = Fixtures.json("events_request").getJSONArray("events").getJSONObject(0)
        assertTrue(o.getString("event_id").matches(Regex("^[0-9a-f-]{36}$")))
        for (k in listOf("name", "revenue_minor", "currency")) assertEquals(fixture.get(k).toString(), o.get(k).toString())
        assertEquals(fixture.getJSONObject("properties").toString(), o.getJSONObject("properties").toString())
        assertEquals("2025-10-20T10:02:41.123Z", o.getString("occurred_at"))
        assertEquals(fixture.keys().asSequence().toSet(), o.keys().asSequence().toSet())
    }

    @Test
    fun moneyOfMinorIsTheDeprecatedConstructor() {
        // Change 09 (X.E10): ClikgateMoney.ofMinor is the name on every platform; the constructor stays as an alias.
        @Suppress("DEPRECATION")
        val old = ClikgateMoney(1_500_000, "NGN")
        assertEquals(old, ClikgateMoney.ofMinor(1_500_000, "NGN"))
        assertEquals(1_500_000L, ClikgateMoney.ofMinor(1_500_000, "NGN").amountMinor)
    }

    @Test
    fun localValidation() {
        fun err(block: () -> Unit): ClikgateError = try {
            block(); throw AssertionError("expected error")
        } catch (e: ClikgateError) { e }
        assertEquals("name", err { Core.buildEvent("bad name", null, null, false, 0) }.param)
        assertEquals("name", err { Core.buildEvent("x".repeat(65), null, null, false, 0) }.param)
        assertEquals("name", err { Core.buildEvent("\$identify", null, null, false, 0) }.param)
        assertEquals("currency", err { Core.buildEvent("purchase", ClikgateMoney.ofMinor(1, "ngn"), null, false, 0) }.param)
        assertEquals("properties", err { Core.buildEvent("p", null, mapOf("big" to "x".repeat(9000)), false, 0) }.param)
        assertEquals("properties", err { Core.buildEvent("p", null, mapOf("obj" to Any()), false, 0) }.param)
        assertEquals(ClikgateError.INVALID_ARGUMENT, err { Core.buildEvent("", null, null, false, 0) }.code)
        // nested properties are fine; revenue is optional
        val ok = Core.buildEvent("a.b:c-d_\$", null, mapOf("n" to mapOf("list" to listOf(1, 2.5, true, null))), false, 0)
        assertFalse(ok.has("revenue_minor"))
        assertEquals("[1,2.5,true,null]", ok.getJSONObject("properties").getJSONObject("n").getJSONArray("list").toString())
    }

    @OptIn(ClikgateInternalApi::class)
    @Test
    fun trackValidatedReportsErrors() {
        installed()
        assertNotNull(Clikgate.trackValidated("bad name", null, null))
        assertNull(Clikgate.trackValidated("signup", null, null))
    }

    @Test
    fun flushesAtTwentyEvents() {
        installed()
        repeat(19) { Clikgate.track("e$it") }
        settle(300)
        assertTrue(env.api.calls("POST /v1/sdk/events").isEmpty())
        Clikgate.track("e19")
        eventually { sentEvents().size == 20 }
        assertEquals((0 until 20).map { "e$it" }, sentEvents().map { it.getString("name") })
        assertNotNull(env.api.calls("POST /v1/sdk/events").first().getHeader("Idempotency-Key"))
        eventually { env.queue.count() == 0 }
    }

    @Test
    fun flushesOnBackgroundAndOnStart() {
        installed()
        Clikgate.track("signup")
        settle(200)
        assertTrue(sentEvents().isEmpty())
        env.core().onBackground()
        eventually { sentEvents().size == 1 }

        // queued in a previous process, flushed on next start
        env.api.on("POST /v1/sdk/events", MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START))
        Clikgate.track("purchase", ClikgateMoney.ofMinor(100, "NGN"))
        env.core().onBackground()
        eventually { env.background.scheduled.get() >= 1 } // offline: WorkManager retry scheduled
        assertEquals(1, env.queue.count())
        env.api.on("POST /v1/sdk/events", ok(Fixtures.text("events_response")))
        env.relaunch()
        eventually { sentEvents().any { it.getString("name") == "purchase" } }
        eventually { env.queue.count() == 0 }
    }

    @Test
    fun eventsBeforeInstallWaitInQueue() {
        env.api.on("POST /v1/sdk/install", MockResponse().setResponseCode(503), MockResponse().setResponseCode(503), ok(Fixtures.text("install_response_organic")))
        env.configure()
        Clikgate.track("early")
        eventually { env.storage.installDone }
        eventually { sentEvents().size == 1 }
        val installAt = env.api.requests.indexOfLast { it.path == "/v1/sdk/install" }
        val eventsAt = env.api.requests.indexOfFirst { it.path == "/v1/sdk/events" }
        assertTrue(eventsAt > installAt)
    }

    @Test
    fun retriesServerErrorsThenSucceedsWithSameEventIds() {
        installed()
        env.api.on("POST /v1/sdk/events", MockResponse().setResponseCode(500), MockResponse().setResponseCode(503), ok(Fixtures.text("events_response")))
        Clikgate.track("signup")
        env.core().onBackground()
        eventually { env.api.calls("POST /v1/sdk/events").size == 3 }
        val ids = sentEvents().map { it.getString("event_id") }.toSet()
        assertEquals(1, ids.size)
        eventually { env.queue.count() == 0 }
    }

    @Test
    fun givesUpAfterFiveAttemptsAndKeepsEvents() {
        installed()
        env.api.on("POST /v1/sdk/events", MockResponse().setResponseCode(500))
        Clikgate.track("signup")
        env.core().onBackground()
        eventually { env.api.calls("POST /v1/sdk/events").size == 5 }
        settle(300)
        assertEquals(5, env.api.calls("POST /v1/sdk/events").size)
        assertEquals(1, env.queue.count())
        assertTrue(env.background.scheduled.get() >= 1)
    }

    @Test
    fun validationErrorDropsBatch() {
        installed()
        env.api.on("POST /v1/sdk/events", errorCode(422, "validation_error"))
        Clikgate.track("signup")
        env.core().onBackground()
        eventually { env.queue.count() == 0 }
        assertEquals(1, env.api.calls("POST /v1/sdk/events").size)
    }

    @Test
    fun rejectedEventsAreDroppedNotRetried() {
        installed()
        env.api.on("POST /v1/sdk/events", ok("""{"accepted":1,"duplicates":0,"rejected":[{"event_id":"x","code":"validation_error","message":"m"}]}"""))
        Clikgate.track("a")
        Clikgate.track("b")
        env.core().onBackground()
        eventually { env.queue.count() == 0 }
        assertEquals(1, env.api.calls("POST /v1/sdk/events").size)
    }

    @Test
    fun queueDropsOldestWhenFull() {
        val q = env.queue
        repeat(5) { q.add(JSONObject().put("event_id", "id$it").put("name", "e$it"), maxEvents = 3, maxBytes = 1_000_000) }
        assertEquals(3, q.count())
        assertEquals(listOf("e2", "e3", "e4"), q.peek(10).map { it.payload.getString("name") })
        // byte limit
        q.clear()
        val big = "x".repeat(400)
        repeat(4) { q.add(JSONObject().put("event_id", "id$it").put("p", big), maxEvents = 1000, maxBytes = 1_000) }
        assertEquals(2, q.count())
        assertEquals(listOf("id2", "id3"), q.peek(10).map { it.payload.getString("event_id") })
    }

    @Test
    fun batchesAreAtMostOneHundred() {
        installed()
        val q = env.queue
        repeat(150) { q.add(Core.buildEvent("e$it", null, null, false, 0), 1000, 1_048_576) }
        env.core().onBackground()
        eventually { env.queue.count() == 0 }
        val sizes = env.api.calls("POST /v1/sdk/events").map { env.api.body(it).getJSONArray("events").length() }
        assertEquals(listOf(100, 50), sizes)
    }

    @Test
    fun flushBlockingForWorker() {
        installed()
        Clikgate.track("signup")
        settle(100)
        assertTrue(env.core().flushBlocking(5_000))
        assertEquals(1, sentEvents().size)
    }

    @Test
    fun identifyIsSentAndClearedWithNull() {
        installed()
        Clikgate.identifyUser(customerId = "user_42", identityToken = "sig.1760954400")
        eventually { env.api.calls("POST /v1/sdk/identify").size == 1 }
        val body = env.api.body(env.api.calls("POST /v1/sdk/identify")[0])
        assertEquals("user_42", body.getString("customer_user_id"))
        assertEquals("sig.1760954400", body.getString("identity_token"))
        eventually { !env.storage.identifyPending }
        Clikgate.identifyUser(customerId = null)
        eventually { env.api.calls("POST /v1/sdk/identify").size == 2 }
        val clear = env.api.body(env.api.calls("POST /v1/sdk/identify")[1])
        assertTrue(clear.isNull("customer_user_id"))
        assertFalse(clear.has("identity_token"))
        eventually { env.storage.customerUserId == null && env.storage.identityToken == null }
    }

    @Test
    fun identifyInvalidTokenKeepsUserId() {
        installed()
        env.api.on("POST /v1/sdk/identify", errorCode(422, "identity_invalid"))
        Clikgate.identifyUser(customerId = "user_42", identityToken = "bad")
        eventually { env.api.calls("POST /v1/sdk/identify").size == 1 }
        eventually { !env.storage.identifyPending }
        assertEquals("user_42", env.storage.customerUserId)
    }

    @Test
    fun identifyBeforeInstallIsSentAfterInstall() {
        Clikgate.identifyUser(customerId = "user_42")
        env.configure()
        eventually { env.api.calls("POST /v1/sdk/identify").size == 1 }
        val installAt = env.api.requests.indexOfFirst { it.path == "/v1/sdk/install" }
        val identifyAt = env.api.requests.indexOfFirst { it.path == "/v1/sdk/identify" }
        assertTrue(identifyAt > installAt)
    }

    // ------------------------------------------------------------ Change 14: identifyUser

    @Test
    fun identifyUserWithOnlyALabelKeepsTheCustomerId() {
        installed()
        Clikgate.identifyUser(customerId = "user_42", identityToken = "sig.1760954400")
        eventually { env.api.calls("POST /v1/sdk/identify").size == 1 && !env.storage.identifyPending }
        Clikgate.identifyUser(label = "  Ada (VIP) ")
        eventually { env.api.calls("POST /v1/sdk/identify").size == 2 && !env.storage.identifyPending }
        val body = env.api.body(env.api.calls("POST /v1/sdk/identify")[1])
        assertEquals("Ada (VIP)", body.getString("label"))
        assertEquals("user_42", body.getString("customer_user_id"))
        assertEquals("sig.1760954400", body.getString("identity_token"))
        assertEquals(null, env.storage.pendingLabel)
        assertEquals("user_42", env.storage.customerUserId)
        // The next identify doesn't resend the label
        Clikgate.identifyUser(customerId = "user_43")
        eventually { env.api.calls("POST /v1/sdk/identify").size == 3 }
        assertFalse(env.api.body(env.api.calls("POST /v1/sdk/identify")[2]).has("label"))
    }

    @Test
    fun identifyUserWithNothingIsANoOpAndLongLabelsAreNotSent() {
        installed()
        Clikgate.identifyUser()
        Clikgate.identifyUser(label = "x".repeat(81))
        settle(300)
        assertTrue(env.api.calls("POST /v1/sdk/identify").isEmpty())
        Clikgate.identifyUser(label = "")
        eventually { env.api.calls("POST /v1/sdk/identify").size == 1 }
        assertEquals("", env.api.body(env.api.calls("POST /v1/sdk/identify")[0]).getString("label"))
    }
}

