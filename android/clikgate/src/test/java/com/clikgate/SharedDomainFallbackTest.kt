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
import com.clikgate.internal.SharedDomains
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.util.concurrent.CopyOnWriteArrayList

/** Unmatched links on shared platform domains open in an in-app browser (change 06, SDK 1.4.0). */
@RunWith(RobolectricTestRunner::class)
class SharedDomainFallbackTest {
    private lateinit var env: TestEnv
    private val links = CopyOnWriteArrayList<ClikgateDeepLink>()
    private val handoffs = CopyOnWriteArrayList<ClikgateBrowserHandoff>()
    private val opened = CopyOnWriteArrayList<String>()

    @Before fun setUp() {
        env = TestEnv()
        env.browser = BrowserOpener { opened.add(it); true }
        Clikgate.onDeepLink { links.add(it) }
        Clikgate.onBrowserHandoff { handoffs.add(it) }
    }

    @After fun tearDown() = env.tearDown()

    private fun view(url: String) = Intent(Intent.ACTION_VIEW, Uri.parse(url))

    private fun installed(options: ClikgateOptions = env.options("inv.myapp.com", "ciz.to", "clk.ng")) {
        env.configure(options)
        eventually { env.storage.installDone }
    }

    @Test
    fun sharedDomainListMatchesTheContract() {
        val fixture = Fixtures.json("shared_link_domains").getJSONArray("shared_link_domains")
        assertEquals((0 until fixture.length()).map { fixture.getString(it) }.toSet(), SharedDomains.HOSTS)
        assertEquals("ciz.to", SharedDomains.host("https://CIZ.TO/a"))
        assertEquals("dev.ciz.to", SharedDomains.host("https://dev.ciz.to/a"))
        assertNull(SharedDomains.host("https://inv.myapp.com/a"))
        assertNull(SharedDomains.host("https://x.ciz.to/a"))
        assertNull(SharedDomains.host("myapp://ciz.to/a"))
    }

    @Test
    fun unmatchedSharedDomainLinkOpensInAppBrowserWithoutDeepLink() {
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_unmatched")))
        installed()
        assertTrue(Clikgate.handleIntent(null, view("https://ciz.to/other-org?utm_source=x")))
        eventually { handoffs.size == 1 }
        assertEquals(listOf("https://ciz.to/other-org?utm_source=x"), opened)
        assertEquals(ClikgateBrowserHandoff("https://ciz.to/other-org?utm_source=x", "ciz.to"), handoffs.single())
        settle(200)
        assertTrue(links.isEmpty())
    }

    @Test
    fun unmatchedCustomDomainLinkKeepsOldBehaviour() {
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_unmatched")))
        installed()
        assertTrue(Clikgate.handleIntent(null, view("https://inv.myapp.com/unknown")))
        eventually { env.api.calls("POST /v1/sdk/resolve").isNotEmpty() }
        settle(300)
        assertTrue(opened.isEmpty())
        assertTrue(handoffs.isEmpty())
        assertTrue(links.isEmpty())
    }

    @Test
    fun matchedSharedDomainLinkIsDeliveredAsBefore() {
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_matched")))
        installed()
        assertTrue(Clikgate.handleIntent(null, view("https://clk.ng/mine")))
        eventually { links.size == 1 }
        assertEquals("/products/42", links.single().path)
        settle(200)
        assertTrue(opened.isEmpty())
        assertTrue(handoffs.isEmpty())
    }

    @Test
    fun fallbackCanBeTurnedOff() {
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_unmatched")))
        installed(env.options("ciz.to").copy(platformDomainBrowserFallback = false))
        assertTrue(Clikgate.handleIntent(null, view("https://ciz.to/other-org")))
        eventually { env.api.calls("POST /v1/sdk/resolve").isNotEmpty() }
        settle(300)
        assertTrue(opened.isEmpty())
        assertTrue(handoffs.isEmpty())
        assertTrue(links.isEmpty())
    }

    @Test
    fun noBrowserMeansNoHandoff() {
        env.browser = BrowserOpener { false }
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_unmatched")))
        installed()
        Clikgate.handleIntent(null, view("https://ciz.to/other-org"))
        eventually { env.api.calls("POST /v1/sdk/resolve").isNotEmpty() }
        settle(300)
        assertTrue(handoffs.isEmpty())
        assertTrue(links.isEmpty())
    }

    @Test
    fun unmatchedSharedLaunchUrlOnFirstLaunchIsResolvedThenHandedOff() {
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_unmatched")))
        Clikgate.handleIntent(null, view("https://ciz.to/other-org"))
        env.configure(env.options("ciz.to"))
        eventually { handoffs.size == 1 }
        assertEquals("https://ciz.to/other-org", env.api.body(env.api.calls("POST /v1/sdk/install").single()).getString("launch_url"))
        assertEquals(1, env.api.calls("POST /v1/sdk/resolve").size)
        assertEquals(listOf("https://ciz.to/other-org"), opened)
    }

    @Test
    fun customDomainLaunchUrlOnFirstLaunchIsNotResolvedAgain() {
        Clikgate.handleIntent(null, view("https://inv.myapp.com/x"))
        env.configure()
        eventually { env.storage.installDone }
        settle(300)
        assertTrue(env.api.calls("POST /v1/sdk/resolve").isEmpty())
        assertTrue(opened.isEmpty())
    }

    // ---- CustomTabsOpener against the (shadowed) package manager

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

    private fun lastStarted(): Intent = shadowOf(app).nextStartedActivity

    @Test
    fun opensCustomTabsInAnExplicitBrowserPackage() {
        addBrowser("org.plain.browser", customTabs = false)
        addBrowser("com.android.chrome", customTabs = true)
        assertTrue(CustomTabsOpener(app).open("https://ciz.to/x"))
        val i = lastStarted()
        assertEquals("com.android.chrome", i.`package`)
        assertEquals(Intent.ACTION_VIEW, i.action)
        assertEquals("https://ciz.to/x", i.dataString)
        assertTrue(i.extras!!.containsKey(CustomTabsOpener.EXTRA_SESSION))
    }

    @Test
    fun fallsBackToAPlainExplicitBrowserIntentWithoutCustomTabs() {
        addBrowser(app.packageName, customTabs = true) // never this app (its App Links would loop)
        addBrowser("org.plain.browser", customTabs = false)
        assertTrue(CustomTabsOpener(app).open("https://clk.ng/x"))
        val i = lastStarted()
        assertEquals("org.plain.browser", i.`package`)
        assertFalse(i.extras?.containsKey(CustomTabsOpener.EXTRA_SESSION) ?: false)
    }

    @Test
    fun noBrowserInstalledOpensNothing() {
        assertFalse(CustomTabsOpener(app).open("https://clk.ng/x"))
        assertNull(shadowOf(app).nextStartedActivity)
    }
}
