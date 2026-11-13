package com.clikgate

import com.clikgate.internal.PushTokenSource
import com.clikgate.internal.ReflectionPushTokenSource
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.atomic.AtomicInteger

/** Firebase Messaging present / absent / failing, for `ClikgateOptions.automaticPushToken`. */
private class FakePushTokens(
    var available: Boolean = true,
    var token: String? = "fcm-auto",
    /** Hold the callback until [complete] (to race a manual token). */
    var deferred: Boolean = false,
) : PushTokenSource {
    val lookups = AtomicInteger()
    @Volatile var pending: ((String?) -> Unit)? = null

    override fun isAvailable(): Boolean = available

    override fun token(cb: (String?) -> Unit) {
        lookups.incrementAndGet()
        if (deferred) pending = cb else cb(token)
    }

    fun complete(t: String?) = pending!!.invoke(t)
}

@RunWith(RobolectricTestRunner::class)
class AutomaticPushTokenTest {
    private lateinit var env: TestEnv
    private lateinit var fcm: FakePushTokens

    @Before fun setUp() {
        env = TestEnv()
        fcm = FakePushTokens()
        env.pushTokens = fcm
    }

    @After fun tearDown() = env.tearDown()

    private fun pushCalls() = env.api.calls("POST /v1/sdk/push-token")

    private fun config(name: String = "config_response", edit: (JSONObject) -> Unit = {}) {
        val o = Fixtures.json(name)
        edit(o)
        env.api.on("GET /v1/sdk/config", FakeApi.ok(o.toString()))
    }

    @Test
    fun fcmTokenIsSentOnLaunchAsFcm() {
        env.configure()
        eventually { pushCalls().size == 1 }
        val body = env.api.body(pushCalls()[0])
        assertEquals("fcm", body.getString("provider"))
        assertEquals("fcm-auto", body.getString("token"))
        assertEquals(1, fcm.lookups.get())
    }

    @Test
    fun oncePerLaunchAndRotatedTokenIsSentOnTheNextLaunch() {
        env.configure()
        eventually { pushCalls().size == 1 && env.storage.pushSentHash != null }
        // more pumps in the same launch: no second lookup
        env.core().onForeground()
        Clikgate.setConsent(analytics = ConsentState.GRANTED)
        Clikgate.goal("purchase", reference = "A-1")
        settle(400)
        assertEquals(1, fcm.lookups.get())

        env.relaunch() // same token: looked up again, nothing sent
        eventually { fcm.lookups.get() == 2 }
        settle(300)
        assertEquals(1, pushCalls().size)

        fcm.token = "fcm-rotated"
        env.relaunch()
        eventually { pushCalls().size == 2 }
        assertEquals("fcm-rotated", env.api.body(pushCalls()[1]).getString("token"))
    }

    @Test
    fun optionOffDoesNothing() {
        env.configure(env.options().copy(automaticPushToken = false))
        eventually { env.storage.installDone }
        settle(400)
        assertEquals(0, fcm.lookups.get())
        assertTrue(pushCalls().isEmpty())
    }

    @Test
    fun uninstallTrackingOffOrMissingDoesNothing() {
        config { it.getJSONObject("features").put("uninstall_tracking", false) }
        env.configure()
        eventually { env.storage.installDone }
        settle(400)
        assertEquals(0, fcm.lookups.get())

        // missing key counts as off (not a default-on feature)
        config { it.getJSONObject("features").remove("uninstall_tracking") }
        env.storage.configFetchedAt = 0
        env.relaunch()
        eventually { env.api.calls("GET /v1/sdk/config").size >= 2 }
        settle(400)
        assertEquals(0, fcm.lookups.get())
        assertTrue(pushCalls().isEmpty())
    }

    @Test
    fun cachedConfigCounts() {
        env.configure(env.options().copy(automaticPushToken = false))
        eventually { env.storage.installDone && env.storage.configJson != null }
        val configCalls = env.api.calls("GET /v1/sdk/config").size
        env.relaunch() // config cached and fresh: no fetch
        eventually { pushCalls().size == 1 }
        assertEquals(configCalls, env.api.calls("GET /v1/sdk/config").size)
    }

    @Test
    fun optedOutDoesNothingUntilTrackingIsBackOn() {
        env.storage.trackingEnabled = false
        env.configure()
        eventually { env.storage.installDone }
        settle(400)
        assertEquals(0, fcm.lookups.get())

        Clikgate.setTrackingEnabled(true)
        eventually { pushCalls().size == 1 }
        assertEquals(1, fcm.lookups.get())
    }

    @Test
    fun blockedVersionDoesNothingEvenWhenPushTokenCallsAreAllowed() {
        config("config_response_blocked") {
            it.put("blocked_instructions", JSONObject().put("allowed_calls", JSONArray(listOf("install", "config", "push_token"))))
        }
        env.configure()
        eventually { env.storage.installDone }
        settle(400)
        assertEquals(0, fcm.lookups.get())
        assertTrue(pushCalls().isEmpty())
    }

    @Test
    fun consentPendingOrDeniedDoesNothingGrantedFetches() {
        config("config_response_consent_required")
        env.configure()
        eventually { env.api.calls("GET /v1/sdk/config").isNotEmpty() }
        settle(400)
        assertEquals(0, fcm.lookups.get())

        Clikgate.setConsent(attribution = ConsentState.DENIED)
        settle(400)
        assertEquals(0, fcm.lookups.get())

        Clikgate.setConsent(attribution = ConsentState.GRANTED)
        eventually { pushCalls().size == 1 }
        assertEquals("fcm-auto", env.api.body(pushCalls()[0]).getString("token"))
        assertEquals(1, fcm.lookups.get())
    }

    @Test
    fun manualTokenBeforeTheLookupWins() {
        Clikgate.setPushToken("manual", PushProvider.FCM) // before configure: applied first
        env.configure()
        eventually { env.storage.installDone }
        settle(400)
        assertEquals(0, fcm.lookups.get())
        // the manual token rides on /install; nothing else is sent
        val install = env.api.body(env.api.calls("POST /v1/sdk/install").single())
        assertEquals("manual", install.getJSONObject("push").getString("token"))
        assertTrue(pushCalls().isEmpty())
        assertEquals("manual", env.storage.pushToken)
    }

    @Test
    fun manualTokenDuringTheLookupWins() {
        fcm.deferred = true
        env.configure()
        eventually { fcm.pending != null }
        Clikgate.setPushToken("manual", PushProvider.FCM)
        eventually { pushCalls().size == 1 }
        fcm.complete("fcm-auto")
        settle(400)
        assertEquals(1, pushCalls().size)
        assertEquals("manual", env.storage.pushToken)
    }

    @Test
    fun firebaseAbsentDoesNothing() {
        fcm.available = false
        env.configure()
        eventually { env.storage.installDone }
        settle(400)
        assertEquals(0, fcm.lookups.get())
        assertTrue(pushCalls().isEmpty())
    }

    @Test
    fun failureIsSilent() {
        fcm.token = null
        env.configure()
        eventually { fcm.lookups.get() == 1 }
        settle(400)
        assertTrue(pushCalls().isEmpty())
        assertNull(env.storage.pushToken)
        // the SDK keeps working
        Clikgate.setPushToken("manual", PushProvider.FCM)
        eventually { pushCalls().size == 1 }
    }

    @Test
    fun reflectionSourceWithoutFirebase() {
        val source = ReflectionPushTokenSource()
        assertFalse(source.isAvailable())
        var result: String? = "unset"
        source.token { result = it }
        assertNull(result)
    }
}
