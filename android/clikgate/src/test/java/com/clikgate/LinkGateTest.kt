package com.clikgate

import android.app.Application
import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.content.pm.ResolveInfo
import android.content.pm.ServiceInfo
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import com.clikgate.FakeApi.Companion.ok
import com.clikgate.internal.BrowserOpener
import com.clikgate.internal.CustomTabsOpener
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.util.concurrent.CopyOnWriteArrayList

/** Change 17 R.2: App Links skip the redirect, so `/resolve` runs the link gates and the SDK honours them. */
@RunWith(RobolectricTestRunner::class)
class LinkGateTest {
    private lateinit var env: TestEnv
    private val links = CopyOnWriteArrayList<ClikgateDeepLink>()
    private val handoffs = CopyOnWriteArrayList<ClikgateBrowserHandoff>()
    private val inApp = CopyOnWriteArrayList<String>()
    private val external = CopyOnWriteArrayList<String>()

    @Before fun setUp() {
        env = TestEnv()
        env.browser = object : BrowserOpener {
            override fun open(url: String): Boolean { inApp.add(url); return true }
            override fun openExternal(url: String): Boolean { external.add(url); return true }
        }
        Clikgate.onDeepLink { links.add(it) }
        Clikgate.onBrowserHandoff { handoffs.add(it) }
    }

    @After fun tearDown() = env.tearDown()

    private fun view(url: String) = Intent(Intent.ACTION_VIEW, Uri.parse(url))

    private fun installed() {
        env.configure(env.options("inv.myapp.com", "ciz.to"))
        eventually { env.storage.installDone }
    }

    private fun gatedWithPayload(fixture: String): String = Fixtures.json(fixture)
        .put("matched", true)
        .put("click_id", "clk_01JAB3C4D5E6F7G8H9JKMNPQRS")
        .put("deep_link", JSONObject().put("url", "https://inv.myapp.com/vip").put("path", "/vip/secret")
            .put("data", JSONObject().put("k", "v")).put("is_deferred", true))
        .put("link", JSONObject().put("id", "lnk_01JAB3C4D5E6F7G8H9JKMNPQRS").put("kind", "standard").put("metadata", JSONObject()))
        .toString()

    @Test
    fun passwordLinkOpensTheSystemBrowserAndDeliversNothing() {
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_password_required")))
        installed()
        assertTrue(Clikgate.handleIntent(null, view("https://inv.myapp.com/vip-offer?utm_source=x")))
        eventually { external.size == 1 }
        assertEquals(listOf("https://inv.myapp.com/vip-offer"), external) // web_url
        settle(200)
        assertTrue(inApp.isEmpty())
        assertTrue(handoffs.isEmpty())
        assertTrue(links.isEmpty())
        assertNull(env.storage.lastClickJson)
    }

    @Test
    fun passwordLinkOnASharedDomainStillUsesTheSystemBrowser() {
        val body = Fixtures.json("resolve_response_password_required").put("web_url", "https://ciz.to/vip")
        env.api.on("POST /v1/sdk/resolve", ok(body.toString()))
        installed()
        Clikgate.handleIntent(null, view("https://ciz.to/vip"))
        eventually { external.size == 1 }
        settle(200)
        assertTrue(inApp.isEmpty())
        assertTrue(handoffs.isEmpty())
    }

    @Test
    fun blockedLinkDeliversTheMessageWithoutARoute() {
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_blocked")))
        installed()
        Clikgate.handleIntent(null, view("https://inv.myapp.com/offer"))
        eventually { links.size == 1 }
        val r = links.single()
        assertEquals("This offer is only for customers in Nigeria.", r.blockMessage)
        assertEquals("https://inv.myapp.com/offer", r.url)
        assertNull(r.path)
        assertNull(r.clickId)
        assertNull(r.link)
        assertNull(r.referral)
        assertNull(r.matchType)
        assertTrue(r.data.isEmpty())
        assertFalse(r.isDeferred)
        assertNull(env.storage.lastClickJson)
        settle(200)
        assertTrue(inApp.isEmpty())
        assertTrue(external.isEmpty())
    }

    @Test
    fun matchedLinkHasNoBlockMessage() {
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_matched")))
        installed()
        Clikgate.handleIntent(null, view("https://inv.myapp.com/p/dress"))
        eventually { links.size == 1 }
        assertNull(links.single().blockMessage)
        assertEquals("/products/42", links.single().path)
    }

    @Test
    fun abTestDeliversTheVariantPathTheServerChose() {
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_ab_variant")))
        installed()
        Clikgate.handleIntent(null, view("https://inv.myapp.com/menu"))
        eventually { links.size == 1 }
        assertEquals("/menu/b", links.single().path)
        assertNotNull(links.single().clickId)
        assertNull(links.single().blockMessage)
    }

    @Test
    fun passwordAnswerCarryingADeferredDeepLinkDeliversNoDestination() {
        env.api.on("POST /v1/sdk/resolve", ok(gatedWithPayload("resolve_response_password_required")))
        installed()
        Clikgate.handleIntent(null, view("https://inv.myapp.com/vip"))
        eventually { external.size == 1 }
        settle(200)
        assertTrue(links.isEmpty())
        assertNull(env.storage.lastClickJson)
    }

    @Test
    fun blockedAnswerCarryingADeferredDeepLinkDeliversNoDestination() {
        env.api.on("POST /v1/sdk/resolve", ok(gatedWithPayload("resolve_response_blocked")))
        installed()
        Clikgate.handleIntent(null, view("https://inv.myapp.com/vip"))
        eventually { links.size == 1 }
        val r = links.single()
        assertNotNull(r.blockMessage)
        assertNull(r.path)
        assertTrue(r.data.isEmpty())
        assertFalse(r.isDeferred)
        assertNull(r.clickId)
        assertNull(r.link)
        assertNull(env.storage.lastClickJson)
    }

    /** First launch: /install gives no deferred deep link for a gated link, so nothing reaches the app. */
    @Test
    fun gatedSharedDomainLaunchUrlOnFirstLaunchDeliversNoDestination() {
        val body = Fixtures.json("resolve_response_password_required").put("web_url", "https://ciz.to/vip")
        env.api.on("POST /v1/sdk/resolve", ok(body.toString()))
        Clikgate.handleIntent(null, view("https://ciz.to/vip"))
        env.configure(env.options("ciz.to"))
        eventually { external.size == 1 }
        assertEquals("https://ciz.to/vip", env.api.body(env.api.calls("POST /v1/sdk/install").single()).getString("launch_url"))
        settle(200)
        assertTrue(links.isEmpty())
        assertTrue(handoffs.isEmpty())
    }

    // ---- First launch on the business's own domain: /install answers for the gated launch URL

    private fun firstLaunch(installFixture: String, url: String) {
        env.api.on("POST /v1/sdk/install", ok(installFixture))
        Clikgate.handleIntent(null, view(url))
        env.configure(env.options("shop.myapp.com"))
        eventually { env.storage.installDone }
    }

    @Test
    fun passwordLaunchUrlOnFirstLaunchOpensTheSystemBrowser() {
        firstLaunch(Fixtures.text("install_response_password_required"), "https://shop.myapp.com/vip-offer")
        eventually { external.size == 1 }
        assertEquals(listOf("https://shop.myapp.com/vip-offer"), external) // web_url
        assertEquals(
            "https://shop.myapp.com/vip-offer",
            env.api.body(env.api.calls("POST /v1/sdk/install").single()).getString("launch_url"),
        )
        settle(200)
        assertTrue(env.api.calls("POST /v1/sdk/resolve").isEmpty()) // no second click
        assertTrue(links.isEmpty())
        assertTrue(inApp.isEmpty())
        assertTrue(handoffs.isEmpty())
    }

    @Test
    fun blockedLaunchUrlOnFirstLaunchDeliversTheBlockedResult() {
        firstLaunch(Fixtures.text("install_response_blocked"), "https://shop.myapp.com/offer")
        eventually { links.size == 1 }
        val r = links.single()
        assertEquals("This offer is only for customers in Nigeria.", r.blockMessage)
        assertEquals("https://shop.myapp.com/offer", r.url)
        assertNull(r.path)
        assertNull(r.clickId)
        assertNull(r.link)
        assertFalse(r.isDeferred)
        settle(200)
        assertEquals(1, links.size)
        assertTrue(external.isEmpty())
        assertTrue(env.api.calls("POST /v1/sdk/resolve").isEmpty())
    }

    @Test
    fun gatedInstallAnswerCarryingADeepLinkDeliversNoDestination() {
        val body = Fixtures.json("install_response_password_required")
            .put("deep_link", JSONObject().put("url", "https://shop.myapp.com/vip").put("path", "/vip/secret")
                .put("data", JSONObject().put("k", "v")).put("is_deferred", true))
        firstLaunch(body.toString(), "https://shop.myapp.com/vip-offer")
        eventually { external.size == 1 }
        settle(200)
        assertTrue(links.isEmpty())
    }

    @Test
    fun gatedSharedDomainLaunchUrlAnsweredByInstallIsNotResolvedAgain() {
        val body = Fixtures.json("install_response_password_required").put("web_url", "https://ciz.to/vip")
        env.api.on("POST /v1/sdk/install", ok(body.toString()))
        Clikgate.handleIntent(null, view("https://ciz.to/vip"))
        env.configure(env.options("ciz.to"))
        eventually { external.size == 1 }
        settle(200)
        assertEquals(1, external.size)
        assertTrue(env.api.calls("POST /v1/sdk/resolve").isEmpty())
        assertTrue(links.isEmpty())
        assertTrue(handoffs.isEmpty())
    }

    @Test
    fun olderServerWithoutStatusBehavesAsBefore() {
        val body = Fixtures.json("resolve_response_matched")
        body.remove("status"); body.remove("web_url"); body.remove("block_message")
        env.api.on("POST /v1/sdk/resolve", ok(body.toString()))
        installed()
        Clikgate.handleIntent(null, view("https://inv.myapp.com/p/dress"))
        eventually { links.size == 1 }
        assertEquals("/products/42", links.single().path)
    }

    // ---- CustomTabsOpener.openExternal against the (shadowed) package manager

    private val app: Application = ApplicationProvider.getApplicationContext()

    private fun addBrowser(pkg: String, customTabs: Boolean) {
        val pm = shadowOf(app.packageManager)
        val probe = Intent(Intent.ACTION_VIEW, Uri.parse("https://example.invalid/")).addCategory(Intent.CATEGORY_BROWSABLE)
        pm.addResolveInfoForIntent(probe, ResolveInfo().apply { activityInfo = ActivityInfo().apply { packageName = pkg; name = "$pkg.Main" } })
        if (customTabs) {
            val service = ComponentName(pkg, "$pkg.Tabs")
            pm.addOrUpdateService(ServiceInfo().apply { packageName = pkg; name = service.className })
            pm.addIntentFilterForService(service, IntentFilter(CustomTabsOpener.CUSTOM_TABS_SERVICE))
        }
    }

    @Test
    fun openExternalUsesThePlainBrowserActivityNeverThisApp() {
        addBrowser(app.packageName, customTabs = true) // never this app (its App Links would loop)
        addBrowser("com.android.chrome", customTabs = true)
        assertTrue(CustomTabsOpener(app).openExternal("https://inv.myapp.com/vip-offer"))
        val i = shadowOf(app).nextStartedActivity
        assertEquals("com.android.chrome", i.`package`)
        assertEquals(Intent.ACTION_VIEW, i.action)
        assertEquals("https://inv.myapp.com/vip-offer", i.dataString)
        assertFalse(i.extras?.containsKey(CustomTabsOpener.EXTRA_SESSION) ?: false) // no Custom Tab
    }
}
