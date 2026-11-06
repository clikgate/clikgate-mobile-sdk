package com.clikgate.sample

import android.content.Intent
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.clikgate.Clikgate
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Checks that links on the configured domain are Clikgate links and that the manifest routes
 * them to MainActivity. Verify App Link ownership on a device with:
 *   adb shell pm verify-app-links --re-verify com.clikgate.sample
 *   adb shell pm get-app-links com.clikgate.sample
 */
@RunWith(AndroidJUnit4::class)
class AppLinkTest {
    private val context = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun linkDomainIsHandledBySdk() {
        val link = Intent(Intent.ACTION_VIEW, Uri.parse("https://${BuildConfig.CLIKGATE_LINK_DOMAIN}/p/dress"))
        assertTrue(Clikgate.handleIntent(null, link))
        assertFalse(Clikgate.handleIntent(null, Intent(Intent.ACTION_VIEW, Uri.parse("https://example.org/x"))))
    }

    @Test
    fun manifestRoutesLinkDomainToMainActivity() {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("https://${BuildConfig.CLIKGATE_LINK_DOMAIN}/p/dress"))
            .addCategory(Intent.CATEGORY_BROWSABLE)
            .setPackage(context.packageName)
        val match = context.packageManager.queryIntentActivities(intent, 0)
        assertTrue(match.any { it.activityInfo.name == MainActivity::class.java.name })
    }
}
