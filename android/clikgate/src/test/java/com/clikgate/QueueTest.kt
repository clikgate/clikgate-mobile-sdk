package com.clikgate

import com.clikgate.FakeApi.Companion.errorCode
import com.clikgate.FakeApi.Companion.ok
import com.clikgate.internal.Goals
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.SocketPolicy
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The persisted queue and its flushing (Change 22: goals only; `track()` and app events were removed), and
 * identifyUser().
 */
@RunWith(RobolectricTestRunner::class)
class QueueTest {
    private lateinit var env: TestEnv

    @Before fun setUp() { env = TestEnv() }

    @After fun tearDown() = env.tearDown()

    private fun installed() {
        env.configure()
        eventually { env.storage.installDone }
        eventually { env.core().isIdleForTests() }
    }

    private fun sentGoals(): List<JSONObject> = env.api.calls("POST /v1/sdk/goals").flatMap { r ->
        val a = env.api.body(r).getJSONArray("goals")
        (0 until a.length()).map { a.getJSONObject(it) }
    }

    private fun queuedGoal(key: String) = Goals.build(key, null, null, null, null, null, null, 0)

    @Test
    fun noTrackOrMoneyApi() {
        // Change 22 (D1): goal() is the only method; there is no track(), trackValidated() or ClikgateMoney.
        val names = Clikgate::class.java.methods.map { it.name }.toSet()
        assertFalse(names.any { it.startsWith("track") })
        assertTrue("goal" in names)
        assertTrue(runCatching { Class.forName("com.clikgate.ClikgateMoney") }.isFailure)
    }

    @Test
    fun flushesAtTwentyGoals() {
        installed()
        repeat(19) { Clikgate.goal("g$it") }
        settle(300)
        assertTrue(env.api.calls("POST /v1/sdk/goals").isEmpty())
        Clikgate.goal("g19")
        eventually { sentGoals().size == 20 }
        assertEquals((0 until 20).map { "g$it" }, sentGoals().map { it.getString("goal") })
        assertNotNull(env.api.calls("POST /v1/sdk/goals").first().getHeader("Idempotency-Key"))
        eventually { env.queue.count() == 0 }
    }

    @Test
    fun flushesOnBackgroundAndOnStart() {
        installed()
        Clikgate.goal("signup")
        settle(200)
        assertTrue(sentGoals().isEmpty())
        env.core().onBackground()
        eventually { sentGoals().size == 1 }

        // queued in a previous process, flushed on next start
        env.api.on("POST /v1/sdk/goals", MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START))
        Clikgate.goal("purchase", reference = "T-1")
        env.core().onBackground()
        eventually { env.background.scheduled.get() >= 1 } // offline: WorkManager retry scheduled
        assertEquals(1, env.queue.count())
        env.api.on("POST /v1/sdk/goals", ok(Fixtures.text("goals_response")))
        env.relaunch()
        eventually { sentGoals().any { it.getString("goal") == "purchase" } }
        eventually { env.queue.count() == 0 }
    }

    @Test
    fun goalsBeforeInstallWaitInQueue() {
        env.api.on("POST /v1/sdk/install", MockResponse().setResponseCode(503), MockResponse().setResponseCode(503), ok(Fixtures.text("install_response_organic")))
        env.configure()
        Clikgate.goal("early_goal")
        eventually { env.storage.installDone }
        env.core().onBackground()
        eventually { sentGoals().size == 1 }
        val installAt = env.api.requests.indexOfLast { it.path == "/v1/sdk/install" }
        val goalsAt = env.api.requests.indexOfFirst { it.path == "/v1/sdk/goals" }
        assertTrue(goalsAt > installAt)
    }

    @Test
    fun retriesServerErrorsThenSucceedsWithTheSameReference() {
        installed()
        env.api.on("POST /v1/sdk/goals", MockResponse().setResponseCode(500), MockResponse().setResponseCode(503), ok(Fixtures.text("goals_response")))
        Clikgate.goal("signup")
        env.core().onBackground()
        eventually { env.api.calls("POST /v1/sdk/goals").size == 3 }
        assertEquals(1, sentGoals().map { it.getString("reference") }.toSet().size)
        eventually { env.queue.count() == 0 }
    }

    @Test
    fun givesUpAfterFiveAttemptsAndKeepsGoals() {
        installed()
        env.api.on("POST /v1/sdk/goals", MockResponse().setResponseCode(500))
        Clikgate.goal("signup")
        env.core().onBackground()
        eventually { env.api.calls("POST /v1/sdk/goals").size == 5 }
        settle(300)
        assertEquals(5, env.api.calls("POST /v1/sdk/goals").size)
        assertEquals(1, env.queue.count())
        assertTrue(env.background.scheduled.get() >= 1)
    }

    @Test
    fun validationErrorDropsBatch() {
        installed()
        env.api.on("POST /v1/sdk/goals", errorCode(422, "validation_error"))
        Clikgate.goal("signup")
        env.core().onBackground()
        eventually { env.queue.count() == 0 }
        assertEquals(1, env.api.calls("POST /v1/sdk/goals").size)
    }

    @Test
    fun queueDropsOldestWhenFull() {
        val q = env.queue
        repeat(5) { q.add(JSONObject().put("goal", "g$it"), maxEvents = 3, maxBytes = 1_000_000, key = "k$it") }
        assertEquals(3, q.count())
        assertEquals(listOf("g2", "g3", "g4"), q.peek(10).map { it.payload.getString("goal") })
        // byte limit
        q.clear()
        val big = "x".repeat(400)
        repeat(4) { q.add(JSONObject().put("goal", "g$it").put("p", big), maxEvents = 1000, maxBytes = 1_000, key = "k$it") }
        assertEquals(2, q.count())
        assertEquals(listOf("g2", "g3"), q.peek(10).map { it.payload.getString("goal") })
    }

    @Test
    fun batchesAreAtMostOneHundred() {
        installed()
        val q = env.queue
        repeat(150) { q.add(queuedGoal("g$it"), 1000, 1_048_576, "k$it") }
        env.core().onBackground()
        eventually { env.queue.count() == 0 }
        val sizes = env.api.calls("POST /v1/sdk/goals").map { env.api.body(it).getJSONArray("goals").length() }
        assertEquals(listOf(100, 50), sizes)
    }

    @Test
    fun appEventsQueuedByAnEarlierBuildAreDroppedWithoutANetworkCall() {
        // Change 22 (S): the queue is persisted. App events left by an earlier development build are dropped on the
        // next flush, never sent; the goals around them are sent.
        installed()
        val q = env.queue
        q.add(JSONObject().put("event_id", "e1").put("name", "purchase").put("occurred_at", "2026-11-01T10:00:00.000Z"), 1000, 1_048_576)
        q.add(queuedGoal("signup"), 1000, 1_048_576, "k1")
        q.add(JSONObject().put("event_id", "e2").put("name", "level_up").put("occurred_at", "2026-11-01T10:00:01.000Z"), 1000, 1_048_576)
        env.core().onBackground()
        eventually { env.queue.count() == 0 }
        assertEquals(listOf("signup"), sentGoals().map { it.getString("goal") })
        assertTrue(env.api.requests.none { it.path!!.startsWith("/v1/sdk/events") }) // no-track-guard: 404 test (the removed route is never called)
    }

    @Test
    fun flushBlockingForWorker() {
        installed()
        Clikgate.goal("signup")
        settle(100)
        assertTrue(env.core().flushBlocking(5_000))
        assertEquals(1, sentGoals().size)
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

