package com.clikgate

import android.content.Intent
import android.net.Uri
import com.clikgate.FakeApi.Companion.ok
import com.clikgate.internal.BrowserOpener
import com.clikgate.internal.ReferrerOutcome
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Change 21 (S.1, S.2, R.2, R.4, R.25): the open payloads the server counts existing-user opens from.
 *
 * - A **direct** App Link open (no redirect) goes to `/resolve` with the URL as opened and the installation in
 *   `Clikgate-Installation-Id` (the server finds the `ins_` row from it): the server records the click.
 * - A **redirect** open carries the redirect's `cg_click_id` inside that URL: the server attaches to that click and
 *   never records a new one. One tap, one `/resolve`, one click.
 * - X's `twclid` travels unchanged in the URLs and the Play install referrer, like `li_fat_id` (change 19 S.2).
 */
@RunWith(RobolectricTestRunner::class)
class Change21Test {
    private lateinit var env: TestEnv
    private val links = CopyOnWriteArrayList<ClikgateDeepLink>()
    private val opened = CopyOnWriteArrayList<String>()

    @Before fun setUp() {
        env = TestEnv()
        env.browser = BrowserOpener { opened.add(it); true }
        Clikgate.onDeepLink { links.add(it) }
    }

    @After fun tearDown() = env.tearDown()

    private fun view(url: String) = Intent(Intent.ACTION_VIEW, Uri.parse(url))
    private fun resolves() = env.api.calls("POST /v1/sdk/resolve")
    private fun installs() = env.api.calls("POST /v1/sdk/install")

    private fun installed() {
        env.configure()
        eventually { env.storage.installDone }
    }

    @Test
    fun directAppLinkOpenSendsTheUrlAndTheInstallation() {
        installed()
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_matched")))
        val url = "https://inv.myapp.com/p/dress"
        Clikgate.handleIntent(null, view(url))
        eventually { links.size == 1 }
        val req = resolves().single()
        val body = env.api.body(req)
        assertEquals(url, body.getString("url"))
        assertFalse("no click id to attach to: the server records this open's click", body.has("click_id"))
        assertEquals(env.storage.installationId(), req.getHeader("Clikgate-Installation-Id"))
    }

    @Test
    fun redirectOpenCarriesTheRedirectClickInOneResolve() {
        installed()
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_matched")))
        val url = "https://inv.myapp.com/p/dress?cg_click_id=$CLICK&cg_link=lnk_01JAB3C4D5E6F7G8H9JKMNPQRS"
        Clikgate.handleIntent(null, view(url))
        eventually { links.size == 1 }
        settle(200)
        val req = resolves().single()
        assertEquals("the click reference reaches the server unchanged", url, env.api.body(req).getString("url"))
        assertEquals(env.storage.installationId(), req.getHeader("Clikgate-Installation-Id"))
        assertTrue("an open never asks for a new click elsewhere", installs().size == 1)
    }

    @Test
    fun redirectOpenOnFirstLaunchGoesWithTheInstallOnly() {
        val url = "https://inv.myapp.com/p/dress?cg_click_id=$CLICK"
        Clikgate.handleIntent(null, view(url))
        installed()
        settle(300)
        val install = installs().single()
        assertEquals(url, env.api.body(install).getString("launch_url"))
        assertEquals(env.storage.installationId(), install.getHeader("Clikgate-Installation-Id"))
        assertTrue("the install already carries the click: no /resolve", resolves().isEmpty())
    }

    @Test
    fun matchedSharedDomainLaunchUrlIsNotResolvedAgain() {
        // /install matched the launch URL (and recorded its click) but the link has no deep link: a /resolve of the
        // same URL would record a second click (R.2).
        val answer = Fixtures.json("install_response_organic").put("status", "matched")
        env.api.on("POST /v1/sdk/install", ok(answer.toString()))
        Clikgate.handleIntent(null, view("https://ciz.to/my-org-link"))
        env.configure(env.options("ciz.to"))
        eventually { env.storage.installDone }
        settle(300)
        assertTrue(resolves().isEmpty())
        assertTrue(opened.isEmpty())
    }

    @Test
    fun openCarriesTheInstallationAndNoUrl() {
        installed()
        env.relaunch()
        env.core().onForeground()
        eventually { env.api.calls("POST /v1/sdk/open").isNotEmpty() }
        val open = env.api.calls("POST /v1/sdk/open").first()
        assertEquals(env.storage.installationId(), open.getHeader("Clikgate-Installation-Id"))
        val body = env.api.body(open)
        assertFalse("URLs go to /resolve, never /open", body.has("url"))
        assertFalse(body.has("click_id"))
    }

    // ---- R.25: X's twclid travels like li_fat_id

    @Test
    fun twclidTravelsInTheResolvedUrl() {
        installed()
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_matched")))
        val url = "https://inv.myapp.com/p/shoes?cg_click_id=$CLICK&twclid=2-abcDEF123xyz"
        Clikgate.handleUrl(url)
        eventually { resolves().isNotEmpty() }
        assertEquals(url, env.api.body(resolves().single()).getString("url"))
    }

    @Test
    fun twclidTravelsInTheLaunchUrlThroughConsentBuffering() {
        env.api.on("GET /v1/sdk/config", ok(Fixtures.text("config_response_consent_required")))
        env.configure(env.options())
        eventually { env.api.calls("GET /v1/sdk/config").isNotEmpty() }
        val launch = "https://inv.myapp.com/p/dress?twclid=TWCLID1"
        Clikgate.handleUrl(launch)
        eventually { links.size == 1 }
        assertEquals("TWCLID1", links.single().data["twclid"])
        assertTrue(installs().isEmpty())
        Clikgate.setConsent(attribution = ConsentState.GRANTED)
        eventually { env.storage.installDone }
        assertEquals(launch, env.api.body(installs().single()).getString("launch_url"))
    }

    @Test
    fun twclidTravelsInTheInstallReferrer() {
        val referrer = "cg_click_id%3D$CLICK%26twclid%3DTWCLID1"
        val base = FakeReferrerSource.fixtureReferrer()
        env.referrer = FakeReferrerSource(listOf(ReferrerOutcome.Ok(base.copy(referrer = referrer))))
        installed()
        val install: JSONObject = env.api.body(installs().single())
        assertEquals(referrer, install.getJSONObject("install_referrer").getString("referrer"))
    }

    private companion object {
        const val CLICK = "clk_01JAB3C4D5E6F7G8H9JKMNPQRS"
    }
}
