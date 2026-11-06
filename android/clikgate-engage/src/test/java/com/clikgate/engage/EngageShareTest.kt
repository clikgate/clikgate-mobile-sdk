package com.clikgate.engage

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import com.clikgate.ClikgateError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class EngageShareTest {
    private val app: Context = ApplicationProvider.getApplicationContext()

    /** Records started intents; packages in [missing] (and the chooser if [noChooser]) aren't installed. */
    private class Recorder(base: Context, val missing: Set<String>, val noChooser: Boolean = false) : ContextWrapper(base) {
        val started = ArrayList<Intent>()
        override fun startActivity(intent: Intent) {
            if (intent.`package` in missing || (noChooser && intent.action == Intent.ACTION_CHOOSER)) throw ActivityNotFoundException()
            started.add(intent)
        }
    }

    @Suppress("DEPRECATION")
    private fun Intent.inner(): Intent = getParcelableExtra(Intent.EXTRA_INTENT)!!

    @Test
    fun whatsAppFirst() {
        val ctx = Recorder(app, emptySet())
        assertTrue(ClikgateEngage.share.whatsApp(ctx, "Join me: https://x/r/A"))
        val i = ctx.started.single()
        assertEquals("com.whatsapp", i.`package`)
        assertEquals(Intent.ACTION_SEND, i.action)
        assertEquals("text/plain", i.type)
        assertEquals("Join me: https://x/r/A", i.getStringExtra(Intent.EXTRA_TEXT))
        assertTrue(i.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
    }

    @Test
    fun whatsAppBusinessThenChooser() {
        val biz = Recorder(app, setOf("com.whatsapp"))
        assertTrue(ClikgateEngage.share.whatsApp(biz, "t"))
        assertEquals("com.whatsapp.w4b", biz.started.single().`package`)

        val none = Recorder(app, setOf("com.whatsapp", "com.whatsapp.w4b"))
        assertFalse(ClikgateEngage.share.whatsApp(none, "t"))
        val chooser = none.started.single()
        assertEquals(Intent.ACTION_CHOOSER, chooser.action)
        assertEquals("t", chooser.inner().getStringExtra(Intent.EXTRA_TEXT))
    }

    @Test
    fun shareUnavailable() {
        val ctx = Recorder(app, setOf("com.whatsapp", "com.whatsapp.w4b"), noChooser = true)
        try {
            ClikgateEngage.share.whatsApp(ctx, "t")
            fail("expected ClikgateError")
        } catch (e: ClikgateError) {
            assertEquals(EngageErrors.SHARE_UNAVAILABLE, e.code)
        }
    }

    @Test
    fun systemShareSheet() {
        val ctx = Recorder(app, emptySet())
        ClikgateEngage.share.system(ctx, "hello", "Invite")
        val chooser = ctx.started.single()
        assertEquals(Intent.ACTION_CHOOSER, chooser.action)
        assertEquals("Invite", chooser.getCharSequenceExtra(Intent.EXTRA_TITLE))
        assertEquals(Intent.ACTION_SEND, chooser.inner().action)
        assertEquals("hello", chooser.inner().getStringExtra(Intent.EXTRA_TEXT))
    }
}
