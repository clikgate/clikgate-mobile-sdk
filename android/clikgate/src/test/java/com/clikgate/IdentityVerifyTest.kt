package com.clikgate

import com.clikgate.FakeApi.Companion.errorCode
import com.clikgate.FakeApi.Companion.ok
import com.clikgate.internal.Core
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.shadows.ShadowLog

/**
 * Change 22 (R.22): `/v1/sdk/identify` answers 200 with `verified: false` and a `reason` for a bad
 * identity token; the SDK keeps the customer ID and logs a warning naming the reason (never the
 * token or the customer ID). Referral calls refused with `403 identity_expired` are logged too.
 */
@RunWith(RobolectricTestRunner::class)
class IdentityVerifyTest {
    private lateinit var env: TestEnv

    @Before fun setUp() {
        env = TestEnv()
        ShadowLog.clear()
    }

    @After fun tearDown() = env.tearDown()

    private fun installed() {
        env.configure(env.options().copy(logLevel = LogLevel.WARN))
        eventually { env.storage.installDone }
        eventually { env.core().isIdleForTests() }
    }

    private fun <T> await(start: (ClikgateCallback<T>) -> Unit): ClikgateResult<T> {
        var result: ClikgateResult<T>? = null
        start { result = it }
        eventually(8_000) { result != null }
        return result!!
    }

    private fun logs() =ShadowLog.getLogsForTag("Clikgate").map { it.msg }

    private fun assertNoSecretsLogged() {
        for (m in logs()) {
            assertFalse(m, "user_42" in m)
            assertFalse(m, "sig.1760954400" in m)
        }
    }

    @Test
    fun expiredTokenKeepsTheCustomerIdAndWarnsWithTheReason() {
        installed()
        env.api.on("POST /v1/sdk/identify", ok(Fixtures.text("identify_response_token_expired")))
        Clikgate.identifyUser(customerId = "user_42", identityToken = "sig.1760954400")
        eventually { env.api.calls("POST /v1/sdk/identify").size == 1 && !env.storage.identifyPending }
        assertEquals("user_42", env.storage.customerUserId)
        eventually { logs().any { "did not verify (expired)" in it } }
        assertTrue(logs().single { "did not verify" in it }.contains("the customer ID is kept but not verified"))
        assertNoSecretsLogged()
    }

    @Test
    fun verifiedFalseWithoutATokenIsNotWarned() {
        installed()
        env.api.on(
            "POST /v1/sdk/identify",
            ok("""{"customer_user_id":"user_42","identity_verified":false,"verified":false,"reason":null}"""),
        )
        Clikgate.identifyUser(customerId = "user_42")
        eventually { env.api.calls("POST /v1/sdk/identify").size == 1 && !env.storage.identifyPending }
        eventually { env.core().isIdleForTests() }
        assertTrue(logs().none { "did not verify" in it })
    }

    @Test
    fun olderServerWithoutVerifiedIsNotWarned() {
        installed()   // the default identify_response fixture has no `verified`
        Clikgate.identifyUser(customerId = "user_42", identityToken = "sig.1760954400")
        eventually { env.api.calls("POST /v1/sdk/identify").size == 1 && !env.storage.identifyPending }
        eventually { env.core().isIdleForTests() }
        assertTrue(logs().none { "did not verify" in it })
    }

    @Test
    fun olderServer422IsStillHandled() {
        installed()
        env.api.on("POST /v1/sdk/identify", errorCode(422, "identity_invalid"))
        Clikgate.identifyUser(customerId = "user_42", identityToken = "sig.1760954400")
        eventually { env.api.calls("POST /v1/sdk/identify").size == 1 && !env.storage.identifyPending }
        assertEquals("user_42", env.storage.customerUserId)
        eventually { logs().any { "did not verify (identity_invalid)" in it } }
        assertNoSecretsLogged()
    }

    @Test
    fun everyReasonReadsInPlainWords() {
        assertTrue("(expired)" in Core.identityTokenNotVerifiedMessage("expired"))
        assertTrue("signature" in Core.identityTokenNotVerifiedMessage("bad_signature"))
        assertTrue("rotated" in Core.identityTokenNotVerifiedMessage("secret_rotated"))
        assertTrue("no identity secret" in Core.identityTokenNotVerifiedMessage("no_secret_set"))
        assertTrue("future" in Core.identityTokenNotVerifiedMessage("not_yet_valid"))
        assertTrue("(no reason given)" in Core.identityTokenNotVerifiedMessage(null))
        assertTrue("(some_new_reason)" in Core.identityTokenNotVerifiedMessage("some_new_reason"))
    }

    @Test
    fun referralCallRefusedWithIdentityExpiredIsSurfacedAndLogged() {
        installed()
        Clikgate.identifyUser(customerId = "user_42", identityToken = "sig.1760954400")
        eventually { !env.storage.identifyPending }
        env.api.on("GET /v1/sdk/referrals/referred-by", errorCode(403, "identity_expired"))
        val err = await<ReferredBy> { Clikgate.referrals.referredBy(it) }.errorOrNull()!!
        assertEquals("identity_expired", err.code)
        assertEquals(403, err.status)
        assertEquals(1, env.api.calls("GET /v1/sdk/referrals/referred-by").size)
        eventually { logs().any { "identity token has expired (identity_expired)" in it } }
        assertNoSecretsLogged()
    }
}
