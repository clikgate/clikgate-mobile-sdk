package com.clikgate.engage

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Every Engage response fixture parses (shared/fixtures). */
@RunWith(RobolectricTestRunner::class)
class EngageFixturesTest {
    @Test
    fun fixturesParse() {
        assertEquals("ADA42X", EngageJson.referralLink(Fixtures.json("referral_link_response")).code)
        assertEquals(12, EngageJson.referralStats(Fixtures.json("referral_stats_response")).clicks)
        val page = EngageJson.leaderboardPage(Fixtures.json("leaderboard_page"))
        assertTrue(page.entries.isNotEmpty())
        val me = EngageJson.myRank(Fixtures.json("my_rank"))
        assertEquals("2026-10-26T23:00:00Z", me.periodEndsAt)
        assertFalse(me.optedOut)
        assertEquals("LAGOS50", EngageJson.redemption(Fixtures.json("code_redemption_response")).code.code)
        assertTrue(EngageJson.isFeatureDisabled(Fixtures.json("feature_disabled")))
        assertFalse(EngageJson.isFeatureDisabled(Fixtures.json("leaderboard_page")))
    }

    @Test
    fun embedUrlIsRead() {
        val o = Fixtures.json("my_rank").put("embed_url", "https://inv.myapp.com/leaderboard/lb?me=t")
        assertEquals("https://inv.myapp.com/leaderboard/lb?me=t", EngageJson.myRank(o).embedUrl)
    }
}
