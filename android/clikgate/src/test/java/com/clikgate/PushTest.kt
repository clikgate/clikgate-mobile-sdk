package com.clikgate

import android.os.Bundle
import okhttp3.mockwebserver.MockResponse
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class PushTest {
    private lateinit var env: TestEnv

    @Before fun setUp() { env = TestEnv() }

    @After fun tearDown() = env.tearDown()

    private fun pushCalls() = env.api.calls("POST /v1/sdk/push-token")

    private fun installed() {
        env.configure()
        eventually { env.storage.installDone }
    }

    @Test
    fun tokenIsSentOnceAndOnlyWhenChanged() {
        installed()
        Clikgate.setPushToken("tok-1", PushProvider.FCM)
        eventually { pushCalls().size == 1 }
        val body = env.api.body(pushCalls()[0])
        assertEquals("fcm", body.getString("provider"))
        assertEquals("tok-1", body.getString("token"))
        assertTrue(body.isNull("apns_environment"))

        Clikgate.setPushToken("tok-1", PushProvider.FCM) // unchanged
        settle(300)
        assertEquals(1, pushCalls().size)

        Clikgate.setPushToken("tok-2", PushProvider.FCM) // refreshed
        eventually { pushCalls().size == 2 }
        assertEquals("tok-2", env.api.body(pushCalls()[1]).getString("token"))
    }

    @Test
    fun relaunchWithSameTokenSendsNothingChangedTokenIsSent() {
        installed()
        Clikgate.setPushToken("tok-1", PushProvider.FCM)
        eventually { pushCalls().size == 1 && env.storage.pushSentHash != null }

        env.relaunch()
        Clikgate.setPushToken("tok-1", PushProvider.FCM)
        env.core().onForeground()
        eventually { env.api.calls("POST /v1/sdk/open").size == 1 }
        settle(200)
        assertEquals(1, pushCalls().size)

        // token stored but its send failed: retried on the next launch without setPushToken
        env.api.on("POST /v1/sdk/push-token", MockResponse().setResponseCode(500))
        Clikgate.setPushToken("tok-3", PushProvider.FCM)
        eventually { pushCalls().size == 6 } // 1 + 5 attempts
        env.api.on("POST /v1/sdk/push-token", FakeApi.ok("""{"ok":true}"""))
        env.relaunch()
        eventually { pushCalls().size == 7 }
        assertEquals("tok-3", env.api.body(pushCalls().last()).getString("token"))
    }

    @Test
    fun providerChangeCountsAsChange() {
        installed()
        Clikgate.setPushToken("same", PushProvider.FCM)
        eventually { pushCalls().size == 1 }
        Clikgate.setPushToken("same", PushProvider.APNS)
        eventually { pushCalls().size == 2 }
        assertEquals("apns", env.api.body(pushCalls()[1]).getString("provider"))
    }

    @Test
    fun isClikgateMessageRecognisesUninstallChecks() {
        fun map(o: JSONObject): Map<String, Any?> = o.keys().asSequence().associateWith { k ->
            val v = o.get(k)
            if (v is JSONObject) map(v) else v
        }
        // FCM data message
        assertTrue(Clikgate.isClikgateMessage(map(Fixtures.json("push_fcm_uninstall_check"))))
        assertTrue(Clikgate.isClikgateMessage(mapOf("cg" to "uc")))
        // APNs-style userInfo (nested)
        assertTrue(Clikgate.isClikgateMessage(map(Fixtures.json("push_apns_uninstall_check"))))
        // nested object delivered as a JSON string in an FCM data map
        assertTrue(Clikgate.isClikgateMessage(mapOf("cg" to """{"t":"uc"}""")))
        // app's own messages
        assertFalse(Clikgate.isClikgateMessage(map(Fixtures.json("push_app_message"))))
        assertFalse(Clikgate.isClikgateMessage(mapOf("cg" to "other")))
        assertFalse(Clikgate.isClikgateMessage(emptyMap<String, String>()))
        assertFalse(Clikgate.isClikgateMessage(null as Map<String, *>?))
        // intent extras
        assertTrue(Clikgate.isClikgateMessage(Bundle().apply { putString("cg", "uc") }))
        assertFalse(Clikgate.isClikgateMessage(Bundle().apply { putString("type", "chat") }))
    }

    @Test
    fun isClikgateMessageWorksWithoutConfigure() {
        assertTrue(Clikgate.isClikgateMessage(mapOf("cg" to "uc")))
    }
}
