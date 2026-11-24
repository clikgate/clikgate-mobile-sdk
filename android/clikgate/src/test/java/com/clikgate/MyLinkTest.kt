package com.clikgate

import com.clikgate.FakeApi.Companion.errorCode
import com.clikgate.FakeApi.Companion.ok
import com.clikgate.engage.ClikgateEngage
import com.clikgate.engage.CoreContextSource
import com.clikgate.engage.EngageErrors
import com.clikgate.engage.ReferralLink
import com.clikgate.engage.ReferralStats
import okhttp3.mockwebserver.MockResponse
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** `referrals.myLink`: the saved link at once, a background refresh, and the stats read when nothing is saved. */
@RunWith(RobolectricTestRunner::class)
class MyLinkTest {
    private lateinit var env: TestEnv
    private val program = "rpg_01JAB3C4D5E6F7G8H9JKMNPQRS"
    private var now = 1_000_000L

    @Before fun setUp() {
        env = TestEnv()
        // Links prepared after identifyUser() are not part of these cases
        env.api.on("POST /v1/sdk/referrals/link", MockResponse().setResponseCode(503))
        env.api.on("GET /v1/sdk/referrals/me", ok(Fixtures.text("referral_stats_response")))
        ClikgateEngage.client.source = CoreContextSource
        ClikgateEngage.client.clock = { now }
        ClikgateEngage.client.retryDelayMs = 1
        ClikgateEngage.clearCache()
    }

    @After fun tearDown() {
        ClikgateEngage.client.clock = System::currentTimeMillis
        ClikgateEngage.client.retryDelayMs = 500
        ClikgateEngage.clearCache()
        env.tearDown()
    }

    private fun <T> await(start: (ClikgateCallback<T>) -> Unit): ClikgateResult<T> {
        var result: ClikgateResult<T>? = null
        start { result = it }
        eventually(8_000) { result != null }
        return result!!
    }

    private fun myLink() = await<ReferralLink> { ClikgateEngage.referrals.myLink(program, it) }

    private fun meCalls() = env.api.calls("GET /v1/sdk/referrals/me")

    private fun signedIn(customer: String = "user_42") {
        env.configure()
        Clikgate.identifyUser(customerId = customer, identityToken = "sig.1760954400")
        eventually { env.storage.customerUserId == customer }
    }

    @Test
    fun firstCallFetchesWithoutWaitingAndSavesTheLink() {
        env.api.on("POST /v1/sdk/install", MockResponse().setResponseCode(503))
        signedIn()
        val link = myLink().getOrThrow()
        assertEquals("ADA42X", link.code)
        assertEquals("https://inv.myapp.com/r/ADA42X", link.url)
        assertEquals("https://inv.myapp.com/a8K2bq", link.shortUrl)
        assertEquals(program, link.programId)
        assertEquals("user_42", meCalls().single().getHeader("Clikgate-Customer-User-Id"))
        val saved = env.core().savedLink(program)!!
        assertNull("only the link fields are saved", saved.opt("stats"))
    }

    @Test
    fun theSavedLinkAnswersWithNoNetworkThenRefreshesAtMostOncePerMinute() {
        signedIn()
        myLink().getOrThrow()
        assertEquals(1, meCalls().size)
        env.api.on("GET /v1/sdk/referrals/me", MockResponse().setResponseCode(503))
        val calls = env.api.requests.size
        // The answer is delivered before any request is made
        var result: ClikgateResult<ReferralLink>? = null
        ClikgateEngage.referrals.myLink(program) { result = it }
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        assertEquals("ADA42X", result!!.getOrThrow().code)
        eventually { meCalls().size >= 2 }
        settle(200)
        assertEquals("ADA42X", myLink().getOrThrow().code)
        settle(200)
        assertEquals("one background refresh within 60 s", 2, meCalls().size)
        assertTrue(env.api.requests.size >= calls + 1)
        now += 60_000
        assertEquals("ADA42X", myLink().getOrThrow().code)
        eventually { meCalls().size == 3 }
    }

    @Test
    fun aBackgroundRefreshUpdatesAChangedUrl() {
        signedIn()
        myLink().getOrThrow()
        val renamed = Fixtures.json("referral_stats_response")
            .put("url", "https://go.myapp.com/r/ADA42X").put("short_url", "https://go.myapp.com/a8K2bq")
        env.api.on("GET /v1/sdk/referrals/me", ok(renamed.toString()))
        now += 60_000
        assertEquals("https://inv.myapp.com/r/ADA42X", myLink().getOrThrow().url)
        eventually { env.core().savedLink(program)?.optString("url") == "https://go.myapp.com/r/ADA42X" }
        val link = myLink().getOrThrow()
        assertEquals("https://go.myapp.com/r/ADA42X", link.url)
        assertEquals("https://go.myapp.com/a8K2bq", link.shortUrl)
    }

    @Test
    fun savedLinksAreKeptPerCustomer() {
        signedIn("user_42")
        myLink().getOrThrow()
        Clikgate.identifyUser(customerId = "user_77", identityToken = "sig.1760954401")
        eventually { env.storage.customerUserId == "user_77" }
        assertNull(env.core().savedLink(program))
        env.api.on("GET /v1/sdk/referrals/me", errorCode(404, "referrer_not_found"))
        assertEquals("referrer_not_found", myLink().errorOrNull()!!.code)
        assertEquals("user_77", meCalls().last().getHeader("Clikgate-Customer-User-Id"))
    }

    @Test
    fun myStatsSavesTheLink() {
        signedIn()
        await<ReferralStats> { ClikgateEngage.referrals.myStats(program, it) }.getOrThrow()
        assertNotNull(env.core().savedLink(program))
        env.api.on("GET /v1/sdk/referrals/me", MockResponse().setResponseCode(503))
        assertEquals("ADA42X", myLink().getOrThrow().code)
    }

    @Test
    fun notIdentifiedWithoutACustomerAndNoNetwork() {
        env.configure()
        eventually { env.storage.installDone }
        val err = myLink().errorOrNull()!!
        assertEquals(EngageErrors.NOT_IDENTIFIED, err.code)
        assertTrue(meCalls().isEmpty())
    }

    @Test
    fun aSwitchedOffFeatureFailsFirst() {
        val o = Fixtures.json("config_response")
        o.getJSONObject("features").put("referrals", false)
        env.api.on("GET /v1/sdk/config", ok(o.toString()))
        signedIn()
        eventually { !Clikgate.isFeatureEnabled("referrals") }
        assertEquals(ClikgateError.FEATURE_DISABLED, myLink().errorOrNull()!!.code)
        assertTrue(meCalls().isEmpty())
    }
}
