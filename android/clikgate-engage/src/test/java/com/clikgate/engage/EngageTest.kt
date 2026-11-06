package com.clikgate.engage

import android.os.Looper
import com.clikgate.ClikgateError
import com.clikgate.engage.FakeApi.Companion.error
import com.clikgate.engage.FakeApi.Companion.errorCode
import com.clikgate.engage.FakeApi.Companion.ok
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine

@RunWith(RobolectricTestRunner::class)
class EngageTest {
    private lateinit var env: EngageEnv
    private val program = "rpg_01JAB3C4D5E6F7G8H9JKMNPQRS"
    private val board = "lb_01JAB3C4D5E6F7G8H9JKMNPQRS"
    private val api get() = env.api

    @Before fun setUp() {
        env = EngageEnv()
        api.on("POST /v1/sdk/referrals/link", ok(Fixtures.text("referral_link_response")))
        api.on("GET /v1/sdk/referrals/me", ok(Fixtures.text("referral_stats_response")))
        api.on("GET /v1/sdk/leaderboards/$board", ok(Fixtures.text("leaderboard_page")))
        api.on("GET /v1/sdk/leaderboards/$board/me", ok(Fixtures.text("my_rank")))
        api.on("GET /v1/sdk/leaderboards/$board/around-me", ok(Fixtures.text("leaderboard_page")))
        api.on("POST /v1/sdk/leaderboards/opt-out", ok("""{"program_id":"$program","opt_out":true}"""))
        api.on("POST /v1/sdk/codes/redeem", ok(Fixtures.text("code_redemption_response")))
    }

    @After fun tearDown() = env.tearDown()

    // ------------------------------------------------------------ parsing + requests

    @Test
    fun createLinkSendsHeadersAndBody() {
        var onMain = false
        var link: ReferralLink? = null
        ClikgateEngage.referrals.createLink(program, "Ada") { r ->
            onMain = Looper.myLooper() == Looper.getMainLooper()
            link = r.getOrThrow()
        }
        eventually { link != null }
        assertTrue(onMain)
        assertEquals("ADA42X", link!!.code)
        assertEquals("https://inv.myapp.com/r/ADA42X", link!!.url)
        assertEquals("https://inv.myapp.com/a8K2bq", link!!.shortUrl)
        assertEquals(program, link!!.programId)
        val req = api.calls("POST /v1/sdk/referrals/link").single()
        assertEquals("cg_sdk_test", req.getHeader("Clikgate-SDK-Key"))
        assertEquals("android/1.0.0", req.getHeader("Clikgate-SDK-Version"))
        assertNull(req.getHeader("Clikgate-SDK-Native-Version"))
        assertEquals("6a1f0c2e-0000-4000-8000-000000000001", req.getHeader("Clikgate-Installation-Id"))
        assertEquals("sig.1760954400", req.getHeader("Clikgate-Identity-Token"))
        assertTrue(req.getHeader("Content-Type")!!.startsWith("application/json"))
        assertEquals(program, api.body(req).getString("program_id"))
        assertEquals("Ada", api.body(req).getString("display_name"))
    }

    @Test
    fun wrapperVersionHeadersAndNoTokenHeader() {
        env.source.sdkVersion = "flutter/1.0.0"
        env.source.nativeVersion = "android/1.0.0"
        env.source.token = null
        await<ReferralLink> { ClikgateEngage.referrals.createLink(program, callback = it) }.getOrThrow()
        val req = api.calls("POST /v1/sdk/referrals/link").single()
        assertEquals("flutter/1.0.0", req.getHeader("Clikgate-SDK-Version"))
        assertEquals("android/1.0.0", req.getHeader("Clikgate-SDK-Native-Version"))
        assertNull(req.getHeader("Clikgate-Identity-Token"))
        assertFalse(api.body(req).has("display_name"))
    }

    @Test
    fun myStatsParsesFixture() {
        val s = await<ReferralStats> { ClikgateEngage.referrals.myStats(program, it) }.getOrThrow()
        assertEquals(listOf(12, 4, 3, 1, 2, 0, 1), listOf(s.clicks, s.installs, s.signups, s.inProgress, s.qualified, s.disqualified, s.rejected))
        assertEquals("active", s.status)
        assertEquals("/v1/sdk/referrals/me?program_id=$program", api.calls("GET /v1/sdk/referrals/me").single().path)
    }

    @Test
    fun leaderboardsParseFixturesAndBuildQueries() {
        val page = await<LeaderboardPage> { ClikgateEngage.leaderboards.top(board, limit = 500, callback = it) }.getOrThrow()
        assertEquals("Weekly top inviters", page.name)
        assertEquals("2026-W43", page.period.key)
        assertEquals("Ada O.", page.entries[0].display)
        assertEquals(3, page.entries[0].pending)
        assertEquals("/v1/sdk/leaderboards/$board?period=current&limit=100", api.calls("GET /v1/sdk/leaderboards/$board").single().path)

        val me = await<MyRank> { ClikgateEngage.leaderboards.me(board, LeaderboardPeriod.PREVIOUS, "lagos", it) }.getOrThrow()
        assertEquals(2, me.rank)
        assertEquals(3, me.gapToNext)
        assertNull(me.embedUrl)
        assertEquals("/v1/sdk/leaderboards/$board/me?period=previous&segment=lagos", api.calls("GET /v1/sdk/leaderboards/$board/me").single().path)

        await<LeaderboardPage> { ClikgateEngage.leaderboards.aroundMe(board, radius = 99, callback = it) }.getOrThrow()
        assertEquals("/v1/sdk/leaderboards/$board/around-me?radius=25&period=current", api.calls("GET /v1/sdk/leaderboards/$board/around-me").single().path)
    }

    /** Runs a suspend block without blocking the (Robolectric) main looper the callbacks need. */
    private fun <T> runSuspend(block: suspend () -> T): Result<T> {
        var result: Result<T>? = null
        block.startCoroutine(Continuation(EmptyCoroutineContext) { result = it })
        eventually { result != null }
        return result!!
    }

    @Test
    fun suspendVariants() {
        assertEquals("ADA42X", runSuspend { ClikgateEngage.referrals.createLink(program) }.getOrThrow().code)
        assertEquals(2, runSuspend { ClikgateEngage.leaderboards.me(board) }.getOrThrow().rank)
        val err = runSuspend { ClikgateEngage.codes.redeem("x") }.exceptionOrNull() as ClikgateError
        assertEquals(ClikgateError.INVALID_ARGUMENT, err.code)
    }

    @Test
    fun setOptOutSendsBodyAndClearsCache() {
        await<MyRank> { ClikgateEngage.leaderboards.me(board, callback = it) }.getOrThrow()
        await<Unit> { ClikgateEngage.leaderboards.setOptOut(program, true, it) }.getOrThrow()
        val body = api.body(api.calls("POST /v1/sdk/leaderboards/opt-out").single())
        assertEquals(program, body.getString("program_id"))
        assertTrue(body.getBoolean("opt_out"))
        await<MyRank> { ClikgateEngage.leaderboards.me(board, callback = it) }.getOrThrow()
        assertEquals(2, api.calls("GET /v1/sdk/leaderboards/$board/me").size)
    }

    @Test
    fun hostedPageUrlFromEmbedUrl() {
        val o = Fixtures.json("my_rank").put("embed_token", "tok").put("embed_url", "https://inv.myapp.com/leaderboard/$board?me=tok")
        api.on("GET /v1/sdk/leaderboards/$board/me", ok(o.toString()))
        val url = await<String> { ClikgateEngage.leaderboards.hostedPageUrl(board, callback = it) }.getOrThrow()
        assertEquals("https://inv.myapp.com/leaderboard/$board?me=tok", url)
        assertEquals("/v1/sdk/leaderboards/$board/me?period=current&embed=1", api.requests.last().path)
        // never cached
        await<String> { ClikgateEngage.leaderboards.hostedPageUrl(board, callback = it) }.getOrThrow()
        assertEquals(2, api.calls("GET /v1/sdk/leaderboards/$board/me").size)
    }

    @Test
    fun hostedPageUnavailableWithoutEmbedUrl() {
        val err = await<String> { ClikgateEngage.leaderboards.hostedPageUrl(board, callback = it) }.errorOrNull()!!
        assertEquals(EngageErrors.HOSTED_PAGE_UNAVAILABLE, err.code)
    }

    @Test
    fun redeemParsesAndValidates() {
        val r = await<Redemption> { ClikgateEngage.codes.redeem(" LAGOS50 ", it) }.getOrThrow()
        assertEquals("oft_01JAB3C4D5E6F7G8H9JKMNPQRS", r.offlineTouchId)
        assertEquals("link", r.code.kind)
        assertNull(r.referral)
        assertEquals("LAGOS50", api.body(api.calls("POST /v1/sdk/codes/redeem").single()).getString("code"))
        assertEquals(ClikgateError.INVALID_ARGUMENT, await<Redemption> { ClikgateEngage.codes.redeem("ab", it) }.errorOrNull()!!.code)
        assertEquals(ClikgateError.INVALID_ARGUMENT, await<Redemption> { ClikgateEngage.codes.redeem("x".repeat(31), it) }.errorOrNull()!!.code)
        assertEquals(1, api.calls("POST /v1/sdk/codes/redeem").size)
    }

    @Test
    fun redeemReferralErrorCarriesOfflineTouchId() {
        api.on("POST /v1/sdk/codes/redeem", errorCode(422, "self_referral", mapOf("offline_touch_id" to "oft_1")))
        val err = await<Redemption> { ClikgateEngage.codes.redeem("ADA42X", it) }.errorOrNull()!!
        assertEquals("self_referral", err.code)
        assertEquals(422, err.status)
        assertEquals("code", err.param)
        assertEquals("oft_1", err.offlineTouchId)
        api.on("POST /v1/sdk/codes/redeem", error(409, Fixtures.text("error_code_expired")))
        assertEquals("code_expired", await<Redemption> { ClikgateEngage.codes.redeem("OLD50", it) }.errorOrNull()!!.code)
    }

    // ------------------------------------------------------------ rules (17A.3)

    @Test
    fun switchedOffFeatureFailsWithoutNetworkOrContext() {
        env.source.disabled += listOf("referrals", "leaderboards", "offline_codes")
        val errors = listOf(
            await<ReferralLink> { ClikgateEngage.referrals.createLink(program, callback = it) }.errorOrNull()!! to "referrals",
            await<ReferralStats> { ClikgateEngage.referrals.myStats(program, it) }.errorOrNull()!! to "referrals",
            await<LeaderboardPage> { ClikgateEngage.leaderboards.top(board, callback = it) }.errorOrNull()!! to "leaderboards",
            await<MyRank> { ClikgateEngage.leaderboards.me(board, callback = it) }.errorOrNull()!! to "leaderboards",
            await<LeaderboardPage> { ClikgateEngage.leaderboards.aroundMe(board, callback = it) }.errorOrNull()!! to "leaderboards",
            await<Unit> { ClikgateEngage.leaderboards.setOptOut(program, true, it) }.errorOrNull()!! to "leaderboards",
            await<String> { ClikgateEngage.leaderboards.hostedPageUrl(board, callback = it) }.errorOrNull()!! to "leaderboards",
            await<Redemption> { ClikgateEngage.codes.redeem("LAGOS50", it) }.errorOrNull()!! to "offline_codes",
        )
        for ((e, f) in errors) {
            assertEquals(ClikgateError.FEATURE_DISABLED, e.code)
            assertEquals(f, e.feature)
        }
        assertEquals(0, env.source.contextCalls)
        assertTrue(api.requests.isEmpty())
    }

    @Test
    fun userCallsNeedIdentifyNoNetwork() {
        env.source.userId = null
        val errors = listOf(
            await<ReferralLink> { ClikgateEngage.referrals.createLink(program, callback = it) }.errorOrNull()!!,
            await<ReferralStats> { ClikgateEngage.referrals.myStats(program, it) }.errorOrNull()!!,
            await<MyRank> { ClikgateEngage.leaderboards.me(board, callback = it) }.errorOrNull()!!,
            await<LeaderboardPage> { ClikgateEngage.leaderboards.aroundMe(board, callback = it) }.errorOrNull()!!,
            await<Unit> { ClikgateEngage.leaderboards.setOptOut(program, false, it) }.errorOrNull()!!,
            await<String> { ClikgateEngage.leaderboards.hostedPageUrl(board, callback = it) }.errorOrNull()!!,
        )
        errors.forEach { assertEquals(EngageErrors.NOT_IDENTIFIED, it.code) }
        assertTrue(api.requests.isEmpty())
        // top and redeem don't need a user
        await<LeaderboardPage> { ClikgateEngage.leaderboards.top(board, callback = it) }.getOrThrow()
        await<Redemption> { ClikgateEngage.codes.redeem("LAGOS50", it) }.getOrThrow()
    }

    @Test
    fun contextErrorsPropagate() {
        env.source.contextError = ClikgateError(ClikgateError.INSTALL_PENDING, "pending")
        assertEquals(ClikgateError.INSTALL_PENDING, await<LeaderboardPage> { ClikgateEngage.leaderboards.top(board, callback = it) }.errorOrNull()!!.code)
        assertTrue(api.requests.isEmpty())
    }

    @Test
    fun identityRequiredFromServerIsTyped() {
        api.on("GET /v1/sdk/referrals/me", errorCode(403, "identity_required"))
        val err = await<ReferralStats> { ClikgateEngage.referrals.myStats(program, it) }.errorOrNull()!!
        assertEquals(EngageErrors.IDENTITY_REQUIRED, err.code)
        assertEquals(403, err.status)
        assertEquals(1, api.requests.size)
    }

    @Test
    fun readsAreCachedFor60Seconds() {
        repeat(3) { await<LeaderboardPage> { ClikgateEngage.leaderboards.top(board, callback = it) }.getOrThrow() }
        assertEquals(1, api.requests.size)
        // different query → different entry
        await<LeaderboardPage> { ClikgateEngage.leaderboards.top(board, limit = 10, callback = it) }.getOrThrow()
        assertEquals(2, api.requests.size)
        env.now += 59_999
        await<LeaderboardPage> { ClikgateEngage.leaderboards.top(board, callback = it) }.getOrThrow()
        assertEquals(2, api.requests.size)
        env.now += 1
        await<LeaderboardPage> { ClikgateEngage.leaderboards.top(board, callback = it) }.getOrThrow()
        assertEquals(3, api.requests.size)
    }

    @Test
    fun cacheIsPerUserAndClearedByWritesAndClearCache() {
        await<ReferralStats> { ClikgateEngage.referrals.myStats(program, it) }.getOrThrow()
        env.source.userId = "user_43"
        await<ReferralStats> { ClikgateEngage.referrals.myStats(program, it) }.getOrThrow()
        assertEquals(2, api.calls("GET /v1/sdk/referrals/me").size)
        await<ReferralLink> { ClikgateEngage.referrals.createLink(program, callback = it) }.getOrThrow()
        await<ReferralStats> { ClikgateEngage.referrals.myStats(program, it) }.getOrThrow()
        assertEquals(3, api.calls("GET /v1/sdk/referrals/me").size)
        await<Redemption> { ClikgateEngage.codes.redeem("LAGOS50", it) }.getOrThrow()
        await<ReferralStats> { ClikgateEngage.referrals.myStats(program, it) }.getOrThrow()
        assertEquals(4, api.calls("GET /v1/sdk/referrals/me").size)
        ClikgateEngage.clearCache()
        await<ReferralStats> { ClikgateEngage.referrals.myStats(program, it) }.getOrThrow()
        assertEquals(5, api.calls("GET /v1/sdk/referrals/me").size)
    }

    @Test
    fun errorsAreNotCached() {
        api.on("GET /v1/sdk/leaderboards/$board", MockResponse().setResponseCode(503), ok(Fixtures.text("leaderboard_page")))
        assertEquals("server_error", await<LeaderboardPage> { ClikgateEngage.leaderboards.top(board, callback = it) }.errorOrNull()!!.code)
        await<LeaderboardPage> { ClikgateEngage.leaderboards.top(board, callback = it) }.getOrThrow()
        assertEquals(2, api.requests.size)
    }

    @Test
    fun oneRetryForNetworkErrorsOnly() {
        // Counted as Engage's own attempts: the JDK / OkHttp URLConnection may itself silently
        // re-send a GET once on a dropped connection (see DECISIONS).
        val attempts = ClikgateEngage.client.attempts
        api.on("GET /v1/sdk/leaderboards/$board", MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST), ok(Fixtures.text("leaderboard_page")))
        await<LeaderboardPage> { ClikgateEngage.leaderboards.top(board, callback = it) }.getOrThrow()
        ClikgateEngage.clearCache()
        attempts.set(0)
        api.on("GET /v1/sdk/leaderboards/$board", MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST))
        assertEquals(ClikgateError.NETWORK_ERROR, await<LeaderboardPage> { ClikgateEngage.leaderboards.top(board, callback = it) }.errorOrNull()!!.code)
        assertEquals(2, attempts.get())
    }

    @Test
    fun noRetryOnHttpErrors() {
        api.on("GET /v1/sdk/leaderboards/$board", MockResponse().setResponseCode(503))
        val err = await<LeaderboardPage> { ClikgateEngage.leaderboards.top(board, callback = it) }.errorOrNull()!!
        assertEquals(503, err.status)
        api.on("GET /v1/sdk/leaderboards/$board", errorCode(429, "rate_limited").setHeader("Retry-After", "0"))
        ClikgateEngage.clearCache()
        assertEquals("rate_limited", await<LeaderboardPage> { ClikgateEngage.leaderboards.top(board, callback = it) }.errorOrNull()!!.code)
        assertEquals(2, api.requests.size)
        // a POST with a 5xx is not retried either
        api.on("POST /v1/sdk/codes/redeem", MockResponse().setResponseCode(502))
        assertEquals(502, await<Redemption> { ClikgateEngage.codes.redeem("LAGOS50", it) }.errorOrNull()!!.status)
        assertEquals(1, api.calls("POST /v1/sdk/codes/redeem").size)
    }

    @Test
    fun featureDisabledBodyIsReportedToCore() {
        api.on("POST /v1/sdk/codes/redeem", ok(Fixtures.text("feature_disabled")))
        val err = await<Redemption> { ClikgateEngage.codes.redeem("LAGOS50", it) }.errorOrNull()!!
        assertEquals(ClikgateError.FEATURE_DISABLED, err.code)
        val reported = Fixtures.json("feature_disabled").getString("feature")
        assertEquals(reported, err.feature)
        assertTrue(env.source.reports.contains(ClikgateError.FEATURE_DISABLED to reported))
        assertTrue(env.source.reports.contains(ClikgateError.FEATURE_DISABLED to "offline_codes"))
    }

    @Test
    fun globalErrorsAreReportedToCore() {
        api.on("GET /v1/sdk/leaderboards/$board", errorCode(401, "invalid_sdk_key"))
        assertEquals("invalid_sdk_key", await<LeaderboardPage> { ClikgateEngage.leaderboards.top(board, callback = it) }.errorOrNull()!!.code)
        api.on("GET /v1/sdk/leaderboards/$board", errorCode(404, "installation_unknown"))
        await<LeaderboardPage> { ClikgateEngage.leaderboards.top(board, callback = it) }
        api.on("GET /v1/sdk/leaderboards/$board", errorCode(404, "leaderboard_not_found"))
        assertEquals(EngageErrors.LEADERBOARD_NOT_FOUND, await<LeaderboardPage> { ClikgateEngage.leaderboards.top(board, callback = it) }.errorOrNull()!!.code)
        assertEquals(listOf("invalid_sdk_key", "installation_unknown"), env.source.reports.map { it.first })
    }

    @Test
    fun invalidArgumentsNoNetwork() {
        assertEquals(ClikgateError.INVALID_ARGUMENT, await<LeaderboardPage> { ClikgateEngage.leaderboards.top(" ", callback = it) }.errorOrNull()!!.code)
        assertEquals(ClikgateError.INVALID_ARGUMENT, await<MyRank> { ClikgateEngage.leaderboards.me("a/b", callback = it) }.errorOrNull()!!.code)
        assertEquals(ClikgateError.INVALID_ARGUMENT, await<ReferralLink> { ClikgateEngage.referrals.createLink("", callback = it) }.errorOrNull()!!.code)
        assertTrue(api.requests.isEmpty())
    }
}
