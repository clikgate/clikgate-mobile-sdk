package com.clikgate.internal

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import java.lang.ref.WeakReference

/**
 * Clikgate's shared platform link domains (the
 * test `shared_link_domains` fixture holds the same list). Many organisations' links live on them,
 * so a link there that `/resolve` doesn't match belongs to another organisation and is opened in an
 * in-app browser instead of being dropped.
 */
internal object SharedDomains {
    val HOSTS: Set<String> = setOf("ciz.to", "clk.ng", "clkg.to", "dev.ciz.to")

    fun host(url: String): String? =
        Uri.parse(url).takeIf { it.scheme.equals("https", true) || it.scheme.equals("http", true) }
            ?.host?.lowercase()?.takeIf { it in HOSTS }
}

/** Opens a URL in an in-app browser (main thread). Returns false when no browser could be opened. */
internal fun interface BrowserOpener {
    fun open(url: String): Boolean

    /** The browser app itself, no Custom Tabs (password links). */
    fun openExternal(url: String): Boolean = open(url)
}

/**
 * Custom Tabs when a browser supports them, else that browser's plain view activity ([openExternal]:
 * always the plain view activity of the default browser, else another one). The intent is
 * always explicit (a browser package): an implicit VIEW intent could resolve to this app's own App
 * Link and loop straight back. Custom Tabs are requested with the protocol extra
 * (`android.support.customtabs.extra.SESSION`) so the SDK doesn't need `androidx.browser`.
 */
internal class CustomTabsOpener(private val context: Context) : BrowserOpener {
    override fun open(url: String): Boolean = open(url, customTabs = true)

    override fun openExternal(url: String): Boolean = open(url, customTabs = false)

    private fun open(url: String, customTabs: Boolean): Boolean {
        val pm = context.packageManager
        val flags = if (Build.VERSION.SDK_INT >= 23) PackageManager.MATCH_ALL else 0
        // Browsers = activities that view any web URL (apps with App Links only match their own hosts).
        val probe = Intent(Intent.ACTION_VIEW, Uri.parse("https://example.invalid/")).addCategory(Intent.CATEGORY_BROWSABLE)
        val own = context.packageName
        val default = pm.resolveActivity(probe, PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo?.packageName
        val browsers = pm.queryIntentActivities(probe, flags).map { it.activityInfo.packageName }
            .filter { it != own }.distinct().sortedBy { if (it == default) 0 else 1 }
        val tabs = pm.queryIntentServices(Intent(CUSTOM_TABS_SERVICE), 0).mapTo(HashSet()) { it.serviceInfo.packageName }
        val pkg = (if (customTabs) browsers.firstOrNull { it in tabs } else null) ?: browsers.firstOrNull() ?: return false
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE).setPackage(pkg)
        if (customTabs && pkg in tabs) intent.putExtras(Bundle().apply { putBinder(EXTRA_SESSION, null) })
        val activity = currentActivity?.get()?.takeUnless { it.isFinishing }
        return try {
            if (activity != null) activity.startActivity(intent)
            else context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (e: Exception) {
            Log.w("Could not open the browser", e)
            false
        }
    }

    companion object {
        const val CUSTOM_TABS_SERVICE = "android.support.customtabs.action.CustomTabsService"
        const val EXTRA_SESSION = "android.support.customtabs.extra.SESSION"

        /** The activity of the last [com.clikgate.Clikgate.handleIntent] (Custom Tabs open over it). */
        @Volatile
        var currentActivity: WeakReference<Activity>? = null
    }
}
