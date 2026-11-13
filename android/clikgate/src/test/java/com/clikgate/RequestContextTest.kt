package com.clikgate

import com.clikgate.FakeApi.Companion.ok
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

/** The internal request context the Engage features use, and its error report-back. */
@OptIn(ClikgateInternalApi::class)
@RunWith(RobolectricTestRunner::class)
class RequestContextTest {
    private lateinit var env: TestEnv

    @Before fun setUp() {
        env = TestEnv()
    }

    @After fun tearDown() = env.tearDown()

    private fun context(): ClikgateResult<ClikgateRequestContext> {
        var result: ClikgateResult<ClikgateRequestContext>? = null
        Clikgate.requestContext { result = it }
        eventually(8_000) { result != null }
        return result!!
    }

    private fun installed() {
        env.configure()
        eventually { env.storage.installDone }
    }

    @Test
    fun notConfigured() {
        assertEquals(ClikgateError.NOT_CONFIGURED, context().errorOrNull()!!.code)
    }

    @Test
    fun snapshotAfterInstall() {
        installed()
        val ctx = context().getOrThrow()
        assertEquals(env.storage.installationId(), ctx.installationId)
        assertEquals("cg_sdk_test", ctx.sdkKey)
        assertEquals("production", ctx.environment)
        assertEquals(env.api.baseUrl, ctx.apiBaseUrl)
        assertNull(ctx.identityToken)
        assertNull(ctx.customerUserId)
        assertEquals("android/${Clikgate.sdkVersion}", ctx.sdkVersion)
        assertNull(ctx.nativeSdkVersion)
        val h = ctx.headers()
        assertEquals("cg_sdk_test", h["Clikgate-SDK-Key"])
        assertEquals(ctx.installationId, h["Clikgate-Installation-Id"])
        assertFalse(h.containsKey("Clikgate-Identity-Token"))
        assertFalse(h.containsKey("Clikgate-SDK-Native-Version"))
    }

    @Test
    fun pendingIdentifyIsSentFirstAndTokenIsIncluded() {
        installed()
        Clikgate.identifyUser(customerId = "user_42", identityToken = "sig.1760954400")
        val ctx = context().getOrThrow()
        assertEquals("user_42", ctx.customerUserId)
        assertEquals("sig.1760954400", ctx.identityToken)
        assertEquals("sig.1760954400", ctx.headers()["Clikgate-Identity-Token"])
        assertEquals(1, env.api.calls("POST /v1/sdk/identify").size)
    }

    @Test
    fun wrapperVersionsAreReported() {
        Clikgate.setWrapper("flutter", "1.2.3")
        installed()
        val ctx = context().getOrThrow()
        assertEquals("flutter/1.2.3", ctx.sdkVersion)
        assertEquals("android/${Clikgate.sdkVersion}", ctx.nativeSdkVersion)
        assertEquals("android/${Clikgate.sdkVersion}", ctx.headers()["Clikgate-SDK-Native-Version"])
    }

    @Test
    fun waitsForInstallThenInstallPending() {
        env.api.on("POST /v1/sdk/install", MockResponse().setResponseCode(503))
        env.configure()
        assertEquals(ClikgateError.INSTALL_PENDING, context().errorOrNull()!!.code)
    }

    @Test
    fun optedOut() {
        installed()
        Clikgate.setTrackingEnabled(false)
        assertEquals(ClikgateError.OPTED_OUT, context().errorOrNull()!!.code)
    }

    @Test
    fun reportedFeatureDisabledSwitchesTheFeatureOffAndRefreshesConfig() {
        installed()
        val configCalls = env.api.calls("GET /v1/sdk/config").size
        val o = Fixtures.json("config_response")
        o.getJSONObject("features").put("leaderboards", false)
        env.api.on("GET /v1/sdk/config", ok(o.toString()))
        assertTrue(Clikgate.isFeatureEnabled("leaderboards"))
        Clikgate.reportServerError(ClikgateError.FEATURE_DISABLED, "leaderboards")
        eventually { !Clikgate.isFeatureEnabled("leaderboards") }
        eventually(message = "config refresh") { env.api.calls("GET /v1/sdk/config").size == configCalls + 1 }
        assertFalse(Clikgate.isFeatureEnabled("leaderboards"))
    }

    @Test
    fun reportedInvalidKeyStopsCalls() {
        installed()
        Clikgate.reportServerError(ClikgateError.INVALID_SDK_KEY, null)
        eventually { context().errorOrNull()?.code == ClikgateError.INVALID_SDK_KEY }
    }

    @Test
    fun otherCodesAreIgnored() {
        installed()
        Clikgate.reportServerError("leaderboard_not_found", null)
        Clikgate.reportServerError(ClikgateError.FEATURE_DISABLED, null)
        assertTrue(context().isSuccess)
        assertTrue(Clikgate.isFeatureEnabled("leaderboards"))
    }
}
