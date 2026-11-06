package com.clikgate

import android.content.Intent
import android.net.Uri
import com.clikgate.FakeApi.Companion.ok
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.CopyOnWriteArrayList

@RunWith(RobolectricTestRunner::class)
class IntentHandlingTest {
    private lateinit var env: TestEnv
    private val links = CopyOnWriteArrayList<ClikgateDeepLink>()

    @Before fun setUp() {
        env = TestEnv()
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_matched")))
        Clikgate.onDeepLink { links.add(it) }
    }

    @After fun tearDown() = env.tearDown()

    private fun view(url: String) = Intent(Intent.ACTION_VIEW, Uri.parse(url))

    private fun installed() {
        env.configure()
        eventually { env.storage.installDone }
    }

    @Test
    fun appLinkOnConfiguredDomainIsResolvedAndDelivered() {
        installed()
        assertTrue(Clikgate.handleIntent(null, view("https://inv.myapp.com/p/dress?utm_source=x")))
        eventually { links.size == 1 }
        val req = env.api.calls("POST /v1/sdk/resolve").single()
        assertEquals("https://inv.myapp.com/p/dress?utm_source=x", env.api.body(req).getString("url"))
        val dl = links.single()
        assertEquals("/products/42", dl.path)
        assertEquals("42", dl.data["product_id"])
        assertFalse(dl.isDeferred)
        assertEquals("clk_01JAB3C4D5E6F7G8H9JKMNPQRS", dl.clickId)
        assertEquals("app_link", dl.matchType)
        assertEquals("off_7", dl.link!!.externalReference)
        assertEquals("cr_91", dl.link!!.metadata["creator_id"])
        assertNull(dl.referral)
    }

    @Test
    fun domainFromServerConfigIsRecognised() {
        installed()
        // ciz.to comes only from config_response.json (options list just inv.myapp.com)
        eventually { env.core().linkDomains.contains("ciz.to") }
        assertTrue(Clikgate.handleIntent(null, view("https://CIZ.TO/abc")))
    }

    @Test
    fun nonClikgateUrlsAreIgnoredWithoutServerCall() {
        installed()
        assertFalse(Clikgate.handleIntent(null, view("https://example.com/p/1")))
        assertFalse(Clikgate.handleIntent(null, view("myapp://product/1")))
        assertFalse(Clikgate.handleIntent(null, Intent(Intent.ACTION_MAIN)))
        assertFalse(Clikgate.handleIntent(null, null))
        settle(200)
        assertTrue(env.api.calls("POST /v1/sdk/resolve").isEmpty())
    }

    @Test
    fun customSchemeWithClickIdIsHandled() {
        installed()
        assertTrue(Clikgate.handleIntent(null, view("myapp://welcome?cg_click_id=clk_01JAB3C4D5E6F7G8H9JKMNPQRS")))
        eventually { links.size == 1 }
        assertEquals(
            "myapp://welcome?cg_click_id=clk_01JAB3C4D5E6F7G8H9JKMNPQRS",
            env.api.body(env.api.calls("POST /v1/sdk/resolve").single()).getString("url"),
        )
    }

    @Test
    fun unmatchedResolveDeliversNothing() {
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_unmatched")))
        installed()
        assertTrue(Clikgate.handleIntent(null, view("https://inv.myapp.com/unknown")))
        eventually { env.api.calls("POST /v1/sdk/resolve").isNotEmpty() }
        settle(200)
        assertTrue(links.isEmpty())
    }

    @Test
    fun sameIntentIsHandledOnce() {
        installed()
        val intent = view("https://inv.myapp.com/p/dress")
        assertTrue(Clikgate.handleIntent(null, intent))
        assertTrue(Clikgate.handleIntent(null, intent)) // e.g. app + Flutter plugin both forward it
        eventually { links.size == 1 }
        settle(200)
        assertEquals(1, env.api.calls("POST /v1/sdk/resolve").size)
    }

    @Test
    fun intentRelaunchedFromRecentsIsIgnored() {
        installed()
        val intent = view("https://inv.myapp.com/p/dress").addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)
        assertFalse(Clikgate.handleIntent(null, intent))
        settle(200)
        assertTrue(env.api.calls("POST /v1/sdk/resolve").isEmpty())
    }

    @Test
    fun warmStartIntentsAreEachResolved() {
        installed()
        assertTrue(Clikgate.handleIntent(null, view("https://inv.myapp.com/p/1")))
        assertTrue(Clikgate.handleIntent(null, view("https://inv.myapp.com/p/2"))) // onNewIntent
        eventually { links.size == 2 }
    }

    @Test
    fun launchUrlBeforeInstallIsSentWithInstall() {
        // Install response for an App Link open (server returns the link's deep link).
        env.api.on("POST /v1/sdk/install", ok(Fixtures.text("install_response_referral")))
        env.api.on("GET /v1/sdk/config", ok(Fixtures.text("config_response")).setBodyDelay(200, java.util.concurrent.TimeUnit.MILLISECONDS))
        env.configure()
        assertTrue(Clikgate.handleIntent(null, view("https://inv.myapp.com/r/ADA42")))
        eventually { env.storage.installDone }
        val body = env.api.body(env.api.calls("POST /v1/sdk/install").single())
        assertEquals("https://inv.myapp.com/r/ADA42", body.getString("launch_url"))
        eventually { links.size == 1 }
        settle(200)
        assertTrue(env.api.calls("POST /v1/sdk/resolve").isEmpty())
    }

    @Test
    fun launchUrlArrivingAfterInstallWasSentIsResolvedAfterwards() {
        env.api.on("POST /v1/sdk/install", ok(Fixtures.text("install_response_organic")).setBodyDelay(300, java.util.concurrent.TimeUnit.MILLISECONDS))
        env.configure()
        eventually { env.api.calls("POST /v1/sdk/install").isNotEmpty() }
        assertTrue(Clikgate.handleIntent(null, view("https://inv.myapp.com/p/dress")))
        eventually { links.size == 1 }
        assertTrue(env.api.body(env.api.calls("POST /v1/sdk/install").single()).isNull("launch_url"))
        assertEquals(1, env.api.calls("POST /v1/sdk/resolve").size)
    }

    @Test
    fun intentBeforeConfigureIsHandledAfterConfigure() {
        assertFalse(Clikgate.handleIntent(null, view("https://inv.myapp.com/p/dress")))
        env.configure()
        eventually { env.storage.installDone }
        val body = env.api.body(env.api.calls("POST /v1/sdk/install").single())
        assertEquals("https://inv.myapp.com/p/dress", body.getString("launch_url"))
    }

    @Test
    fun handleUrlStringOverload() {
        installed()
        assertTrue(Clikgate.handleUrl("https://inv.myapp.com/p/dress"))
        eventually { links.size == 1 }
    }

    @Test
    fun linksBeforeListenerAreBufferedLatestTen() {
        Clikgate.onDeepLink(null)
        installed()
        repeat(12) { Clikgate.handleUrl("https://inv.myapp.com/p/$it") }
        eventually { env.api.calls("POST /v1/sdk/resolve").size == 12 }
        settle(300)
        Clikgate.onDeepLink { links.add(it) }
        eventually { links.size == 10 }
        settle(100)
        assertEquals(10, links.size)
    }
}
