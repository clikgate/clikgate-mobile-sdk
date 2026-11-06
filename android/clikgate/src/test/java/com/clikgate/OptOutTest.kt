package com.clikgate

import android.content.Intent
import android.net.Uri
import okhttp3.mockwebserver.MockResponse
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.CopyOnWriteArrayList

@RunWith(RobolectricTestRunner::class)
class OptOutTest {
    private lateinit var env: TestEnv

    @Before fun setUp() { env = TestEnv() }

    @After fun tearDown() = env.tearDown()

    private fun installed() {
        env.configure()
        eventually { env.storage.installDone }
        eventually { env.core().isIdleForTests() }
    }

    @Test
    fun optOutClearsQueueSendsOptOutAndStopsCalls() {
        installed()
        Clikgate.track("a")
        Clikgate.track("b")
        eventually { env.queue.count() == 2 }
        Clikgate.setTrackingEnabled(false)
        eventually { env.api.calls("POST /v1/sdk/opt-out").size == 1 }
        assertTrue(env.api.body(env.api.calls("POST /v1/sdk/opt-out")[0]).getBoolean("opt_out"))
        assertEquals(0, env.queue.count())
        eventually { env.storage.pendingOptOut == null }

        val before = env.api.requests.size
        Clikgate.track("c")
        Clikgate.identifyUser(customerId = "user_42")
        Clikgate.setPushToken("tok", PushProvider.FCM)
        env.core().onBackground()
        settle(300)
        assertEquals(before, env.api.requests.size)
        assertEquals(0, env.queue.count())

        // stays opted out across launches
        env.relaunch()
        env.core().onForeground()
        settle(300)
        assertEquals(before, env.api.requests.size)

        // referral calls report opted_out
        var err: ClikgateError? = null
        Clikgate.referrals.referredBy { err = it.errorOrNull() }
        eventually { err != null }
        assertEquals(ClikgateError.OPTED_OUT, err!!.code)
    }

    @Test
    fun optOutIsRetriedUntilItSucceedsAndPersisted() {
        installed()
        env.api.on("POST /v1/sdk/opt-out", MockResponse().setResponseCode(503), MockResponse().setResponseCode(500), FakeApi.ok("""{"opt_out":true}"""))
        Clikgate.setTrackingEnabled(false)
        eventually { env.api.calls("POST /v1/sdk/opt-out").size == 3 }
        eventually { env.storage.pendingOptOut == null }
    }

    @Test
    fun pendingOptOutIsSentOnNextLaunch() {
        installed()
        env.api.on("POST /v1/sdk/opt-out", MockResponse().setResponseCode(503))
        Clikgate.setTrackingEnabled(false)
        eventually { env.api.calls("POST /v1/sdk/opt-out").isNotEmpty() }
        assertEquals(true, env.storage.pendingOptOut)
        env.api.on("POST /v1/sdk/opt-out", FakeApi.ok("""{"opt_out":true}"""))
        env.relaunch()
        eventually { env.storage.pendingOptOut == null }
    }

    @Test
    fun optInResumes() {
        installed()
        Clikgate.setTrackingEnabled(false)
        eventually { env.storage.pendingOptOut == null && env.api.calls("POST /v1/sdk/opt-out").size == 1 }
        Clikgate.setTrackingEnabled(true)
        eventually { env.api.calls("POST /v1/sdk/opt-out").size == 2 }
        assertFalse(env.api.body(env.api.calls("POST /v1/sdk/opt-out")[1]).getBoolean("opt_out"))
        eventually { env.storage.pendingOptOut == null }
        Clikgate.track("back")
        env.core().onBackground()
        eventually { env.api.calls("POST /v1/sdk/events").size == 1 }
        // no new install
        assertEquals(1, env.api.calls("POST /v1/sdk/install").size)
    }

    @Test
    fun optOutBeforeFirstInstallSendsMinimalInstallAndNothingElse() {
        Clikgate.setTrackingEnabled(false)
        Clikgate.setPushToken("tok", PushProvider.FCM)
        env.configure()
        eventually { env.storage.installDone }
        settle(300)
        val install = env.api.calls("POST /v1/sdk/install").single()
        val body = env.api.body(install)
        // Change 09 (X.E23): the four-purpose object says it, every purpose denied; no tracking_allowed.
        val consent = body.getJSONObject("consent")
        for (p in listOf("analytics", "attribution", "ad_user_data", "ad_personalization")) assertEquals("denied", consent.getString(p))
        assertFalse(consent.has("tracking_allowed"))
        assertFalse(body.has("install_referrer"))
        assertFalse(body.has("push"))
        assertFalse(body.has("device_model"))
        assertEquals(0, env.referrer.calls.get())
        assertEquals(listOf("/v1/sdk/install"), env.api.requests.map { it.path })
        assertNull(env.storage.pendingOptOut)
    }

    @Test
    fun deepLinksStillReachTheAppWhenOptedOut() {
        installed()
        Clikgate.setTrackingEnabled(false)
        eventually { env.storage.pendingOptOut == null }
        val links = CopyOnWriteArrayList<ClikgateDeepLink>()
        Clikgate.onDeepLink { links.add(it) }
        assertTrue(Clikgate.handleIntent(null, Intent(Intent.ACTION_VIEW, Uri.parse("https://inv.myapp.com/p/dress?x=1"))))
        eventually { links.size == 1 }
        assertEquals("/p/dress", links[0].path)
        assertEquals("1", links[0].data["x"])
        assertTrue(env.api.calls("POST /v1/sdk/resolve").isEmpty())
    }
}
