package com.clikgate

import com.clikgate.FakeApi.Companion.ok
import com.clikgate.internal.ReferrerData
import com.clikgate.internal.ReferrerOutcome
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Change 19 (R.20 S.2): LinkedIn `li_fat_id` and Snap `ScCid` reach Clikgate in the URLs and the Play install
 * referrer the server reads itself (the redirect adds them only when the app's `pass_ad_click_ids` allows it).
 */
@RunWith(RobolectricTestRunner::class)
class Change19Test {
    private lateinit var env: TestEnv
    private val links = CopyOnWriteArrayList<ClikgateDeepLink>()

    @Before fun setUp() {
        env = TestEnv()
        Clikgate.onDeepLink { links.add(it) }
    }

    @After fun tearDown() = env.tearDown()

    private fun installs() = env.api.calls("POST /v1/sdk/install")

    @Test
    fun linkedInAndSnapIdsTravelInTheResolvedUrl() {
        env.api.on("GET /v1/sdk/config", ok(Fixtures.text("config_response")))
        env.configure(env.options())
        eventually { env.storage.installDone }

        val opened = "https://inv.myapp.com/p/shoes?li_fat_id=LIFAT2&ScCid=SNAP2"
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_matched")))
        Clikgate.handleUrl(opened)
        eventually { env.api.calls("POST /v1/sdk/resolve").isNotEmpty() }
        assertEquals(opened, env.api.body(env.api.calls("POST /v1/sdk/resolve").last()).getString("url"))
    }

    @Test
    fun keptThroughConsentBuffering() {
        env.api.on("GET /v1/sdk/config", ok(Fixtures.text("config_response_consent_required")))
        env.configure(env.options())
        eventually { env.api.calls("GET /v1/sdk/config").isNotEmpty() }
        val launch = "https://inv.myapp.com/p/dress?cg_click_id=clk_1&li_fat_id=LIFAT1&ScCid=SNAP1"
        Clikgate.handleUrl(launch)
        eventually { links.size == 1 }
        assertTrue(installs().isEmpty())

        Clikgate.setConsent(attribution = ConsentState.GRANTED)
        eventually { env.storage.installDone }
        assertEquals(launch, env.api.body(installs().single()).getString("launch_url"))
    }

    @Test
    fun theInstallReferrerIsSentAsPlayGaveIt() {
        val referrer = "cg_click_id%3Dclk_01JAB3C4D5E6F7G8H9JKMNPQRS%26cg_link%3Dlnk_01JAB3C4D5E6F7G8H9JKMNPQRS%26li_fat_id%3DLIFAT1%26ScCid%3DSNAP1"
        val base = FakeReferrerSource.fixtureReferrer()
        env.referrer = FakeReferrerSource(listOf(ReferrerOutcome.Ok(base.copy(referrer = referrer))))
        env.api.on("GET /v1/sdk/config", ok(Fixtures.text("config_response")))
        env.configure(env.options())
        eventually { env.storage.installDone }
        val install: JSONObject = env.api.body(installs().single())
        assertEquals(referrer, install.getJSONObject("install_referrer").getString("referrer"))
    }
}
