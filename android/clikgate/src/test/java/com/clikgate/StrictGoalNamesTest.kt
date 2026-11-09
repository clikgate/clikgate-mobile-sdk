package com.clikgate

import com.clikgate.FakeApi.Companion.error
import com.clikgate.FakeApi.Companion.ok
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.shadows.ShadowLog
import java.math.BigDecimal
import java.util.concurrent.ConcurrentHashMap

/**
 * An organisation that accepts only goals it has set up: `refused` / `unknown_goal` and `goal_archived` are final
 * (no retry, no re-queue), only the server decides, and debug builds log the goal name only.
 */
@RunWith(RobolectricTestRunner::class)
class StrictGoalNamesTest {
    private lateinit var env: TestEnv
    private val results = ConcurrentHashMap<String, GoalResult>()

    @Before fun setUp() {
        env = TestEnv()
        ShadowLog.clear()
    }

    @After fun tearDown() = env.tearDown()

    private fun installed(debuggable: Boolean) {
        env.device = object : FakeDevice(env.context) {
            override val isDebuggableApp = debuggable
        }
        env.configure(env.options().copy(logLevel = LogLevel.WARN))
        eventually { env.storage.installDone }
        eventually { env.core().isIdleForTests() }
    }

    private fun collect(name: String) = GoalResultListener { results[name] = it }

    private fun logs() = ShadowLog.getLogsForTag("Clikgate").map { it.msg }

    private fun goalCalls() = env.api.calls("POST /v1/sdk/goals")

    @Test
    fun unknownAndArchivedAreFinalAndLoggedInDebugBuilds() {
        env.api.on("POST /v1/sdk/goals", ok(Fixtures.text("goals_response_refused_unknown_goal")))
        installed(debuggable = true)
        Clikgate.goal("level_complete", value = BigDecimal("2500"), currency = "NGN", reference = "APP-11", label = "vip", onResult = collect("unknown"))
        Clikgate.goal("old_signup", reference = "APP-12", onResult = collect("archived"))
        assertTrue(env.core().flushBlocking(3_000))
        eventually { results.size == 2 }
        assertEquals(GoalResult(GoalStatus.REFUSED, "unknown_goal", null, false), results["unknown"])
        assertEquals(GoalResult(GoalStatus.REFUSED, "goal_archived", GoalKind.STANDARD, false), results["archived"])
        // Dropped from the persisted queue and never sent again.
        assertEquals(0, env.queue.count())
        settle(300)
        assertEquals(1, goalCalls().size)

        val lines = logs()
        assertEquals(1, lines.count { it == "Goal `level_complete` isn't set up in Clikgate" })
        assertFalse(lines.any { it.contains("old_signup") && it.contains("isn't set up") })
        // The goal name only: never the reference, the value or the label.
        assertFalse(lines.any { it.contains("APP-11") || it.contains("2500") || it.contains("vip") })
    }

    @Test
    fun noLineInReleaseBuilds() {
        env.api.on("POST /v1/sdk/goals", ok(Fixtures.text("goals_response_refused_unknown_goal")))
        installed(debuggable = false)
        Clikgate.goal("level_complete", reference = "APP-11", onResult = collect("unknown"))
        Clikgate.goal("old_signup", reference = "APP-12")
        assertTrue(env.core().flushBlocking(3_000))
        eventually { results.size == 1 }
        assertEquals("unknown_goal", results["unknown"]?.reason)
        assertFalse(logs().any { it.contains("isn't set up") })
    }

    @Test
    fun wholeRequest422RefusalIsFinal() {
        env.api.on("POST /v1/sdk/goals", error(422, Fixtures.text("goal_refusal_unknown_goal")))
        installed(debuggable = true)
        Clikgate.goal("level_complete", reference = "APP-11", onResult = collect("unknown"))
        assertTrue(env.core().flushBlocking(3_000))
        eventually { results.size == 1 }
        assertEquals(GoalResult(GoalStatus.REFUSED, "unknown_goal", null, false), results["unknown"])
        assertEquals(0, env.queue.count())
        settle(300)
        assertEquals(1, goalCalls().size)
        assertEquals(1, logs().count { it == "Goal `level_complete` isn't set up in Clikgate" })
    }

    @Test
    fun wholeRequest422ArchivedIsFinal() {
        env.api.on("POST /v1/sdk/goals", error(422, Fixtures.text("goal_refusal_goal_archived")))
        installed(debuggable = true)
        Clikgate.goal("old_signup", reference = "APP-12", onResult = collect("archived"))
        assertTrue(env.core().flushBlocking(3_000))
        eventually { results.size == 1 }
        assertEquals(GoalResult(GoalStatus.REFUSED, "goal_archived", null, false), results["archived"])
        assertEquals(0, env.queue.count())
        settle(300)
        assertEquals(1, goalCalls().size)
        assertFalse(logs().any { it.contains("isn't set up") })
    }

    @Test
    fun theDeviceNeverChecksNamesOrRemembersTheRefusal() {
        env.api.on("POST /v1/sdk/goals", ok(Fixtures.text("goals_response_refused_unknown_goal")))
        installed(debuggable = true)
        Clikgate.goal("level_complete", reference = "APP-11", onResult = collect("first"))
        assertTrue(env.core().flushBlocking(3_000))
        eventually { results.containsKey("first") }
        // The organisation may have set the goal up since: the next call goes to the server again.
        env.api.on("POST /v1/sdk/goals", ok(Fixtures.text("goals_response")))
        Clikgate.goal("level_complete", reference = "APP-13", onResult = collect("second"))
        assertTrue(env.core().flushBlocking(3_000))
        eventually { results.containsKey("second") }
        assertEquals(GoalStatus.COUNTED, results["second"]?.status)
        assertEquals(2, goalCalls().size)
        assertEquals("level_complete", env.api.body(goalCalls()[1]).getJSONArray("goals").getJSONObject(0).getString("goal"))
    }
}
