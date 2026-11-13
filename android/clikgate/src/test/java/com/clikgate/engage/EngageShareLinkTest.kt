package com.clikgate.engage

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.os.Bundle
import androidx.test.core.app.ApplicationProvider
import com.clikgate.ClikgateError
import com.clikgate.engage.FakeApi.Companion.ok
import org.junit.After
import org.junit.Before
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Change 13 S.1: share.link / share.referralLink, the chooser callback and share events. */
@RunWith(RobolectricTestRunner::class)
class EngageShareLinkTest {
    private val app: Context = ApplicationProvider.getApplicationContext()
    private lateinit var env: EngageEnv
    private val referral = ReferralLink("rfr_1", "rpg_1", "ADA42X", "https://inv.myapp.com/r/ADA42X", "https://inv.myapp.com/a8K2bq")

    @Before fun setUp() {
        env = EngageEnv()
        env.api.on("POST /v1/share-events", ok(Fixtures.text("share_event_response")))
    }

    @After fun tearDown() = env.tearDown()

    /** The share events sent so far, after [expected] of them arrived. */
    private fun recorded(expected: Int): List<Pair<String, ShareApp>> {
        if (expected > 0) eventually { env.api.calls("POST /v1/share-events").size >= expected } else Thread.sleep(100)
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        return env.api.calls("POST /v1/share-events").map { r ->
            val b = env.api.body(r)
            b.getString("url") to appOf(b.getString("app"))
        }
    }

    private class Recorder(base: Context, val missing: Set<String> = emptySet(), val noChooser: Boolean = false) : ContextWrapper(base) {
        val started = ArrayList<Intent>()
        override fun startActivity(intent: Intent) {
            val missingPkg = intent.`package` in missing
            val missingDefault = intent.action == Intent.ACTION_SENDTO && "default" in missing
            if (missingPkg || missingDefault || (noChooser && intent.action == Intent.ACTION_CHOOSER)) throw ActivityNotFoundException()
            started.add(intent)
        }
    }

    @Suppress("DEPRECATION")
    private fun Intent.inner(): Intent = getParcelableExtra(Intent.EXTRA_INTENT)!!

    private fun appOf(value: String): ShareApp = ShareApp.entries.first { it.value == value }

    @Test
    fun sharedCasesGiveEachAppItsLink() {
        val cases = Fixtures.json("share_cases")
        val links = cases.getJSONArray("links")
        for (i in 0 until links.length()) {
            val c = links.getJSONObject(i)
            val code = if (c.has("code")) c.getString("code") else null
            val got = EngageShare.withEnding(c.getString("url"), appOf(c.getString("app")), code)
            assertEquals(c.toString(), c.getString("expected"), got)
        }
        val texts = cases.getJSONArray("texts")
        for (i in 0 until texts.length()) {
            val c = texts.getJSONObject(i)
            val message = if (c.isNull("message")) null else c.getString("message")
            assertEquals(c.getString("expected"), EngageShare.text(message, c.getString("url")))
        }
        val packages = cases.getJSONObject("android_packages")
        for (pkg in packages.keys()) assertEquals(pkg, packages.getString(pkg), EngageShare.appFor(pkg).value)
    }

    @Test
    fun shareAppValuesMatchTheContract() {
        assertEquals(15, ShareApp.entries.size)
        assertEquals(Fixtures.text("share_event_request").contains("\"other\""), true)
        assertEquals("other", ShareApp.OTHER.value)
    }

    @Test
    fun shareMenuGivesEachKnownPackageItsOwnLink() {
        val ctx = Recorder(app)
        assertFalse(ClikgateEngage.share.link(ctx, "https://inv.myapp.com/summer", "Join me", chooserTitle = "Share"))
        val chooser = ctx.started.single()
        assertEquals(Intent.ACTION_CHOOSER, chooser.action)
        assertEquals("Join me https://inv.myapp.com/summer", chooser.inner().getStringExtra(Intent.EXTRA_TEXT))
        val extras: Bundle = chooser.getBundleExtra(Intent.EXTRA_REPLACEMENT_EXTRAS)!!
        assertEquals(EngageShare.PACKAGES.size, extras.keySet().size)
        val wa = extras.getBundle("com.whatsapp")!!.getString(Intent.EXTRA_TEXT)!!
        val waBiz = extras.getBundle("com.whatsapp.w4b")!!.getString(Intent.EXTRA_TEXT)!!
        val gmail = extras.getBundle("com.google.android.gm")!!.getString(Intent.EXTRA_TEXT)!!
        assertEquals(wa, waBiz)
        assertTrue(wa.startsWith("Join me https://inv.myapp.com/summer-"))
        assertTrue(gmail != wa && gmail.startsWith("Join me https://inv.myapp.com/summer-"))
        // The callback: an explicit, mutable broadcast to the Engage receiver carrying each app's link.
        val pending = android.app.PendingIntent.getBroadcast(
            app, EngageShare.requestCodes.get(), Intent(app, ClikgateShareReceiver::class.java),
            android.app.PendingIntent.FLAG_NO_CREATE or android.app.PendingIntent.FLAG_MUTABLE,
        )
        assertNotNull(pending)
        val callback = org.robolectric.Shadows.shadowOf(pending).savedIntent
        assertEquals("https://inv.myapp.com/summer", callback.getStringExtra(EngageShare.EXTRA_PLAIN))
        assertTrue(callback.getBundleExtra(EngageShare.EXTRA_URLS)!!.getString("whatsapp")!!.startsWith("https://inv.myapp.com/summer-"))
        assertTrue(recorded(0).isEmpty())
    }

    @Test
    fun givenShareUrlsAreUsedAsTheyAre() {
        val ctx = Recorder(app)
        val given = mapOf(ShareApp.WHATSAPP to "https://inv.myapp.com/summer-z")
        ClikgateEngage.share.link(ctx, "https://inv.myapp.com/summer", shareUrls = given)
        val extras = ctx.started.single().getBundleExtra(Intent.EXTRA_REPLACEMENT_EXTRAS)!!
        assertEquals("https://inv.myapp.com/summer-z", extras.getBundle("com.whatsapp")!!.getString(Intent.EXTRA_TEXT))
    }

    @Test
    fun directShareTriesEachPackageAndRecords() {
        val ctx = Recorder(app, setOf("com.whatsapp"))
        assertTrue(ClikgateEngage.share.link(ctx, "https://inv.myapp.com/summer", app = ShareApp.WHATSAPP))
        val i = ctx.started.single()
        assertEquals("com.whatsapp.w4b", i.`package`)
        assertEquals(Intent.ACTION_SEND, i.action)
        assertEquals(EngageShare.withEnding("https://inv.myapp.com/summer", ShareApp.WHATSAPP, null), i.getStringExtra(Intent.EXTRA_TEXT))
        assertEquals(listOf(i.getStringExtra(Intent.EXTRA_TEXT)!! to ShareApp.WHATSAPP), recorded(1))
    }

    @Test
    fun directSmsFallsBackToTheDefaultSmsApp() {
        val ctx = Recorder(app, setOf("com.google.android.apps.messaging", "com.samsung.android.messaging"))
        assertTrue(ClikgateEngage.share.link(ctx, "https://inv.myapp.com/summer", "Hi", ShareApp.SMS))
        val i = ctx.started.single()
        assertEquals(Intent.ACTION_SENDTO, i.action)
        assertEquals("smsto:", i.dataString)
        assertTrue(i.getStringExtra("sms_body")!!.startsWith("Hi https://inv.myapp.com/summer-"))
        assertEquals(ShareApp.SMS, recorded(1).single().second)
    }

    @Test
    fun directShareWithoutTheAppOpensTheMenu() {
        val ctx = Recorder(app, EngageShare.PACKAGES.toSet() + "default")
        assertFalse(ClikgateEngage.share.link(ctx, "https://inv.myapp.com/summer", app = ShareApp.EMAIL))
        assertEquals(Intent.ACTION_CHOOSER, ctx.started.single().action)
        // Apps without packages (Slack, YouTube on Android) open the menu too.
        val other = Recorder(app)
        assertFalse(ClikgateEngage.share.link(other, "https://inv.myapp.com/summer", app = ShareApp.SLACK))
        assertEquals(Intent.ACTION_CHOOSER, other.started.single().action)
        assertTrue(recorded(0).isEmpty())
    }

    @Test
    fun shareUnavailable() {
        try {
            ClikgateEngage.share.link(Recorder(app, noChooser = true), "https://inv.myapp.com/summer")
            fail("expected ClikgateError")
        } catch (e: ClikgateError) {
            assertEquals(EngageErrors.SHARE_UNAVAILABLE, e.code)
        }
    }

    @Test
    fun referralLinkKeepsTheCodeAndRecordsTheReferralUrl() {
        val ctx = Recorder(app)
        assertTrue(ClikgateEngage.share.referralLink(ctx, referral, app = ShareApp.TELEGRAM))
        val text = ctx.started.single().getStringExtra(Intent.EXTRA_TEXT)!!
        assertEquals(EngageShare.withEnding(referral.url, ShareApp.TELEGRAM, "ADA42X"), text)
        assertTrue(text.startsWith("https://inv.myapp.com/r/ADA42X-"))
        assertEquals(text, recorded(1).single().first)
    }

    @Test
    fun receiverRecordsThePickedApp() {
        val ctx = Recorder(app)
        ClikgateEngage.share.link(ctx, "https://inv.myapp.com/summer")
        val urls = Bundle().apply { putString("whatsapp", "https://inv.myapp.com/summer-z") }
        val picked = Intent().putExtra(EngageShare.EXTRA_URLS, urls).putExtra(EngageShare.EXTRA_PLAIN, "https://inv.myapp.com/summer")
            .putExtra(Intent.EXTRA_CHOSEN_COMPONENT, ComponentName("com.whatsapp", "com.whatsapp.ContactPicker"))
        ClikgateShareReceiver().onReceive(app, picked)
        val unknown = Intent(picked).putExtra(Intent.EXTRA_CHOSEN_COMPONENT, ComponentName("com.example.notes", "Main"))
        ClikgateShareReceiver().onReceive(app, unknown)
        ClikgateShareReceiver().onReceive(app, Intent(picked).apply { removeExtra(Intent.EXTRA_CHOSEN_COMPONENT) })
        assertEquals(
            setOf("https://inv.myapp.com/summer-z" to ShareApp.WHATSAPP, "https://inv.myapp.com/summer" to ShareApp.OTHER),
            recorded(2).toSet(),
        )
    }

    @Test
    fun recordPostsAShareEvent() {
        env.source.disabled.addAll(listOf("referrals", "leaderboards", "offline_codes"))
        EngageShare.record("https://inv.myapp.com/summer-z", ShareApp.WHATSAPP)
        assertEquals(listOf("https://inv.myapp.com/summer-z" to ShareApp.WHATSAPP), recorded(1))
        val req = env.api.calls("POST /v1/share-events").single()
        assertEquals("cg_sdk_test", req.getHeader("Clikgate-SDK-Key"))
        assertEquals(2, env.api.body(req).length())
    }
}
