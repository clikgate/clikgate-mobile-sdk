package com.clikgate

import com.clikgate.FakeApi.Companion.error
import com.clikgate.FakeApi.Companion.errorCode
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

@RunWith(RobolectricTestRunner::class)
class ReferralsTest {
    private lateinit var env: TestEnv
    private val program = "rpg_01JAB3C4D5E6F7G8H9JKMNPQRS"

    @Before fun setUp() {
        env = TestEnv()
        env.api.on("POST /v1/sdk/referrals/apply-code", ok(Fixtures.text("referral")))
        env.api.on("GET /v1/sdk/referrals/referred-by", ok(Fixtures.text("referred_by_response")))
    }

    @After fun tearDown() = env.tearDown()

    private fun <T> await(start: (ClikgateCallback<T>) -> Unit): ClikgateResult<T> {
        var result: ClikgateResult<T>? = null
        start { result = it }
        eventually(8_000) { result != null }
        return result!!
    }

    private fun installed() {
        env.configure()
        eventually { env.storage.installDone }
    }

    @Test
    fun applyCodeReturnsReferral() {
        installed()
        val referral = await<Referral> { Clikgate.referrals.applyCode(program, " ADA42 ", it) }.getOrThrow()
        assertEquals("code_entry", referral.source)
        assertEquals("installed", referral.status)
        assertEquals("ref_01JAB3C4D5E6F7G8H9JKMNPQRS", referral.referralId)
        assertEquals("ADA42", env.api.body(env.api.calls("POST /v1/sdk/referrals/apply-code").single()).getString("code"))
    }

    @Test
    fun applyCodeErrorIsMappedAndNotRetried() {
        installed()
        env.api.on("POST /v1/sdk/referrals/apply-code", error(404, Fixtures.text("error_code_not_found")))
        val err = await<Referral> { Clikgate.referrals.applyCode(program, "NOPE", it) }.errorOrNull()!!
        assertEquals("code_not_found", err.code)
        assertEquals(404, err.status)
        assertEquals("code", err.param)
        assertEquals("No active referrer has this code.", err.message)
        assertEquals(1, env.api.calls("POST /v1/sdk/referrals/apply-code").size)
    }

    @Test
    fun everyReferralErrorCodeIsSurfaced() {
        installed()
        for (code in listOf("already_referred", "window_expired", "self_referral", "program_paused", "manual_entry_disabled", "referrer_blocked")) {
            env.api.on("POST /v1/sdk/referrals/apply-code", errorCode(422, code))
            val err = await<Referral> { Clikgate.referrals.applyCode(program, "ADA42", it) }.errorOrNull()!!
            assertEquals(code, err.code)
        }
        for (code in listOf("not_identified", "identity_required", "identity_invalid")) {
            env.api.on("GET /v1/sdk/referrals/referred-by", errorCode(403, code))
            assertEquals(code, await<ReferredBy> { Clikgate.referrals.referredBy(it) }.errorOrNull()!!.code)
        }
    }

    @Test
    fun rateLimitIsRetriedThenSucceeds() {
        installed()
        env.api.on(
            "GET /v1/sdk/referrals/referred-by",
            error(429, Fixtures.text("error_rate_limited")).setHeader("Retry-After", "0"),
            ok(Fixtures.text("referred_by_response")),
        )
        val info = await<ReferredBy> { Clikgate.referrals.referredBy(it) }.getOrThrow()
        assertTrue(info.referred)
        assertEquals("holding", info.referral!!.status)
        assertEquals("Ada", info.referral!!.referrerDisplayName)
        assertEquals(2, env.api.calls("GET /v1/sdk/referrals/referred-by").size)
    }

    @Test
    fun persistentServerErrorIsReported() {
        installed()
        env.api.on("GET /v1/sdk/referrals/referred-by", MockResponse().setResponseCode(503))
        val err = await<ReferredBy> { Clikgate.referrals.referredBy(it) }.errorOrNull()!!
        assertEquals("server_error", err.code)
        assertEquals(503, err.status)
        assertEquals(3, env.api.calls("GET /v1/sdk/referrals/referred-by").size)
    }

    @Test
    fun notReferredResponse() {
        installed()
        env.api.on("GET /v1/sdk/referrals/referred-by", ok("""{"referred":false,"referral":null}"""))
        val info = await<ReferredBy> { Clikgate.referrals.referredBy(it) }.getOrThrow()
        assertFalse(info.referred)
        assertNull(info.referral)
    }

    @Test
    fun notConfiguredError() {
        val err = await<ReferredBy> { Clikgate.referrals.referredBy(it) }.errorOrNull()!!
        assertEquals(ClikgateError.NOT_CONFIGURED, err.code)
    }

    @Test
    fun invalidArgumentsAreRejectedLocally() {
        installed()
        assertEquals(ClikgateError.INVALID_ARGUMENT, await<Referral> { Clikgate.referrals.applyCode(program, "  ", it) }.errorOrNull()!!.code)
        assertEquals(ClikgateError.INVALID_ARGUMENT, await<Referral> { Clikgate.referrals.applyCode("", "ADA42", it) }.errorOrNull()!!.code)
    }

    @Test
    fun callBeforeInstallWaitsThenReportsInstallPending() {
        env.api.on("POST /v1/sdk/install", MockResponse().setResponseCode(503))
        env.configure()
        val err = await<ReferredBy> { Clikgate.referrals.referredBy(it) }.errorOrNull()!!
        assertEquals(ClikgateError.INSTALL_PENDING, err.code)
    }

    @Test
    fun callDuringInstallWaitsForIt() {
        env.api.on("POST /v1/sdk/install", MockResponse().setResponseCode(503), ok(Fixtures.text("install_response_organic")))
        env.configure()
        val info = await<ReferredBy> { Clikgate.referrals.referredBy(it) }.getOrThrow()
        assertTrue(info.referred)
    }

    @Test
    fun applyCodeSendsIdentityTokenAfterPendingIdentify() {
        installed()
        Clikgate.identifyUser(customerId = "user_42", identityToken = "sig.1760954400")
        await<Referral> { Clikgate.referrals.applyCode(program, "ADA42", it) }.getOrThrow()
        val req = env.api.calls("POST /v1/sdk/referrals/apply-code").single()
        assertEquals("sig.1760954400", req.getHeader("Clikgate-Identity-Token"))
        assertTrue(env.api.requests.indexOfFirst { it.path == "/v1/sdk/identify" } < env.api.requests.indexOf(req))
    }

    @Test
    fun noIdentityHeaderWithoutToken() {
        installed()
        await<ReferredBy> { Clikgate.referrals.referredBy(it) }.getOrThrow()
        assertNull(env.api.calls("GET /v1/sdk/referrals/referred-by").single().getHeader("Clikgate-Identity-Token"))
    }
}
