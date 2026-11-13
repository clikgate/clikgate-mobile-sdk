package com.clikgate.engage

import android.app.Activity
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import com.clikgate.ClikgateCallback
import com.clikgate.ClikgateError
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicInteger
import java.util.regex.Pattern

/**
 * Share helpers (`ClikgateEngage.share`). Call on the main thread; pass an Activity where possible
 * (otherwise the share starts in a new task).
 *
 * - [link] / [referralLink]: the phone's share menu with a Clikgate link. Each app Clikgate knows
 *   gets its own version of the link (a short ending that tells Clikgate where it was shared);
 *   other apps get the plain link. The share is recorded with `POST /v1/share-events` (the app and
 *   the link, no personal data); it is a share count, never a click.
 * - [system] / [whatsApp]: plain text, no ending and nothing recorded.
 */
public object EngageShare {
    internal val WHATSAPP_PACKAGES = listOf("com.whatsapp", "com.whatsapp.w4b")
    // <generated:packages> (scripts/generate_share_targets.py; do not edit by hand)
    /** Android packages Clikgate knows, in the order a direct share tries them, and their apps. */
    internal val PACKAGES: Array<String> = arrayOf("com.whatsapp", "com.whatsapp.w4b", "com.instagram.android", "com.facebook.katana", "com.facebook.orca", "com.zhiliaoapp.musically", "com.ss.android.ugc.trill", "com.zhiliaoapp.musically.go", "com.tiktok.lite.go", "com.twitter.android", "com.linkedin.android", "org.telegram.messenger", "org.thunderdog.challegram", "com.google.android.gm", "com.google.android.apps.messaging", "com.samsung.android.messaging")
    internal val PACKAGE_APPS: Array<ShareApp> = arrayOf(ShareApp.WHATSAPP, ShareApp.WHATSAPP, ShareApp.INSTAGRAM, ShareApp.FACEBOOK, ShareApp.FACEBOOK, ShareApp.TIKTOK, ShareApp.TIKTOK, ShareApp.TIKTOK, ShareApp.TIKTOK, ShareApp.X, ShareApp.LINKEDIN, ShareApp.TELEGRAM, ShareApp.TELEGRAM, ShareApp.EMAIL, ShareApp.SMS, ShareApp.SMS)
    // </generated:packages>
    internal const val EXTRA_URLS = "com.clikgate.engage.share.URLS"
    internal const val EXTRA_PLAIN = "com.clikgate.engage.share.PLAIN"
    internal val requestCodes = AtomicInteger()
    private val IGNORE = ClikgateCallback<Unit> { }
    private val ENDING = Pattern.compile("-(?:[qQ][0-9]+|[A-Za-z])$")
    private val HTTP = Pattern.compile("^(https?://[^/?#]+)([^?#]*)(\\?[^#]*)?(#.*)?$", Pattern.CASE_INSENSITIVE)

    /**
     * Opens the system share sheet (`ACTION_SEND` text/plain in a chooser).
     * @throws ClikgateError [EngageErrors.SHARE_UNAVAILABLE] when nothing can show it.
     */
    public fun system(context: Context, text: String, chooserTitle: CharSequence? = null) {
        try {
            context.startActivity(chooser(context, text, chooserTitle))
        } catch (e: ActivityNotFoundException) {
            throw unavailable(e)
        }
    }

    /**
     * Shares [text] straight into WhatsApp (`ACTION_SEND` for `com.whatsapp`, then WhatsApp Business
     * `com.whatsapp.w4b`), else the system share sheet. Returns true when WhatsApp itself opened,
     * false when the share sheet was used. No `<queries>` manifest entry is needed (the intent is
     * started and `ActivityNotFoundException` triggers the fallback).
     * @throws ClikgateError [EngageErrors.SHARE_UNAVAILABLE] when even the share sheet can't start.
     */
    public fun whatsApp(context: Context, text: String): Boolean {
        for (pkg in WHATSAPP_PACKAGES) {
            if (tryStart(context, send(text).setPackage(pkg))) return true
        }
        system(context, text)
        return false
    }

    /**
     * Shares a Clikgate link ([url], e.g. `https://inv.myapp.com/summer`) with an optional [message]
     * in front of it.
     *
     * Without [app], opens the share menu: each app Clikgate knows gets its own version of the link,
     * other apps the plain link, and the app the person picks is recorded (when the phone reports
     * it). With [app], shares straight into that app (WhatsApp, Instagram, Telegram, Gmail, ...),
     * falling back to the share menu when it isn't installed.
     *
     * [shareUrls]: the link's `share_urls` from your backend (the Clikgate API's link object), used
     * as they are. Returns true when [app] itself opened, false when the share menu was shown.
     * @throws ClikgateError [EngageErrors.SHARE_UNAVAILABLE] when nothing can share text.
     */
    public fun link(
        context: Context,
        url: String,
        message: String? = null,
        app: ShareApp? = null,
        shareUrls: Map<ShareApp, String>? = null,
        chooserTitle: CharSequence? = null,
    ): Boolean = start(context, url, null, shareUrls, message, app, chooserTitle)

    /**
     * [link] for the user's referral link ([EngageReferrals.createLink]): the version for each app
     * keeps the referral code, so the referrer is still credited.
     */
    public fun referralLink(
        context: Context,
        link: ReferralLink,
        message: String? = null,
        app: ShareApp? = null,
        chooserTitle: CharSequence? = null,
    ): Boolean = start(context, link.url, link.code, null, message, app, chooserTitle)

    // ------------------------------------------------------------------ internals

    /**
     * [url] with the ending for [app] (none for apps without one), replacing an ending it already
     * has. A referral [code] in the query (`?ref=CODE`) gets the ending; otherwise the last path
     * segment does. URLs that aren't http(s) or have no path are returned unchanged.
     */
    internal fun withEnding(url: String, app: ShareApp?, code: String?): String {
        val m = HTTP.matcher(url)
        if (!m.matches()) return url
        val origin = m.group(1)!!
        val rawPath = m.group(2) ?: ""
        val query = m.group(3) ?: ""
        val fragment = m.group(4) ?: ""
        val suffix = app?.ending?.let { "-$it" } ?: ""
        if (code != null && query.length > 1) {
            // ?a=1&ref=CODE&b=2: the first parameter whose value is the code (with or without an ending)
            var start = 1
            while (start < query.length) {
                var end = query.indexOf('&', start)
                if (end < 0) end = query.length
                val eq = query.indexOf('=', start)
                if (eq in (start + 1) until end && strip(query.substring(eq + 1, end)) == code) {
                    return origin + rawPath + query.substring(0, eq + 1) + code + suffix + query.substring(end) + fragment
                }
                start = end + 1
            }
        }
        val path = rawPath.trimEnd('/')
        if (path.isEmpty()) return url
        val slash = path.lastIndexOf('/')
        return origin + path.substring(0, slash + 1) + strip(path.substring(slash + 1)) + suffix + query + fragment
    }

    private fun strip(segment: String): String = ENDING.matcher(segment).replaceFirst("")

    internal fun text(message: String?, url: String): String =
        if (message.isNullOrBlank()) url else message.trim() + " " + url

    /** The app behind an Android package (other when Clikgate doesn't know it). */
    internal fun appFor(pkg: String?): ShareApp {
        val i = PACKAGES.indexOf(pkg)
        return if (i < 0) ShareApp.OTHER else PACKAGE_APPS[i]
    }

    /**
     * Shares [url] (the given `share_urls` win; a referral's [code] keeps its place) and records the version shared
     * (the API resolves referral URLs with endings too).
     */
    @Suppress("LongParameterList")
    private fun start(
        context: Context, url: String, code: String?, given: Map<ShareApp, String>?,
        message: String?, app: ShareApp?, title: CharSequence?,
    ): Boolean {
        val n = PACKAGES.size
        if (app != null) {
            // Straight into the app: its packages in order, then the default SMS / email app.
            val text = text(message, given?.get(app) ?: withEnding(url, app, code))
            var opened = false
            for (i in 0 until n) {
                if (!opened && PACKAGE_APPS[i] == app) opened = tryStart(context, send(text).setPackage(PACKAGES[i]))
            }
            if (!opened && (app == ShareApp.SMS || app == ShareApp.EMAIL)) {
                val sms = app == ShareApp.SMS
                val intent = Intent(Intent.ACTION_SENDTO, Uri.parse(if (sms) "smsto:" else "mailto:"))
                opened = tryStart(context, intent.putExtra(if (sms) "sms_body" else Intent.EXTRA_TEXT, text))
            }
            if (opened) {
                record(given?.get(app) ?: withEnding(url, app, code), app)
                return true
            }
        }
        val extras = Bundle()
        val urls = Bundle()
        for (i in 0 until n) {
            val a = PACKAGE_APPS[i]
            val texts = Bundle()
            texts.putString(Intent.EXTRA_TEXT, text(message, given?.get(a) ?: withEnding(url, a, code)))
            extras.putBundle(PACKAGES[i], texts)
            urls.putString(a.value, given?.get(a) ?: withEnding(url, a, code))
        }
        val target = send(text(message, withEnding(url, null, code)))
        val chooser = if (Build.VERSION.SDK_INT >= 22) {
            val callback = Intent(context, ClikgateShareReceiver::class.java)
                .putExtra(EXTRA_URLS, urls)
                .putExtra(EXTRA_PLAIN, withEnding(url, null, code))
            // Mutable (the system writes the chosen app into it) and explicit (Android 14 requires it).
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
            val pending = PendingIntent.getBroadcast(context, requestCodes.incrementAndGet(), callback, flags)
            Intent.createChooser(target, title, pending.intentSender)
        } else {
            Intent.createChooser(target, title)
        }
        chooser.putExtra(Intent.EXTRA_REPLACEMENT_EXTRAS, extras)
        try {
            context.startActivity(newTask(context, chooser))
        } catch (e: ActivityNotFoundException) {
            throw unavailable(e)
        }
        return false
    }

    private fun tryStart(context: Context, intent: Intent): Boolean = try {
        context.startActivity(newTask(context, intent))
        true
    } catch (_: ActivityNotFoundException) {
        false
    }

    /** `POST /v1/share-events` (SDK key; no feature switch, nothing cached; failures are dropped). */
    internal fun record(url: String, app: ShareApp) {
        val body = JSONObject().put("url", url).put("app", app.value)
        ClikgateEngage.client.call("", "POST", "/v1/share-events", body, userCall = false, cacheable = false, write = false,
            kind = EngageJson.UNIT, callback = IGNORE)
    }

    private fun unavailable(e: Exception) = ClikgateError(EngageErrors.SHARE_UNAVAILABLE, "No app can share text on this device", cause = e)

    private fun send(text: String) = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, text)
    }

    private fun newTask(context: Context, intent: Intent): Intent {
        if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return intent
    }

    internal fun chooser(context: Context, text: String, chooserTitle: CharSequence?): Intent =
        newTask(context, Intent.createChooser(send(text), chooserTitle))
}

/**
 * Receives the app picked in [EngageShare.link]'s share menu (the chooser's IntentSender callback)
 * and records the share. Declared in the Engage manifest, not exported.
 */
internal class ClikgateShareReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = chosenApp(intent) ?: return
        val url = intent.getBundleExtra(EngageShare.EXTRA_URLS)?.getString(app.value)
            ?: intent.getStringExtra(EngageShare.EXTRA_PLAIN) ?: return
        EngageShare.record(url, app)
    }

    /** Android 15+ `EXTRA_CHOOSER_RESULT` when present ("copy" counts as other), else `EXTRA_CHOSEN_COMPONENT`. */
    @Suppress("DEPRECATION")
    @android.annotation.SuppressLint("InlinedApi") // the callback only exists on API 22+
    internal fun chosenApp(intent: Intent): ShareApp? {
        if (Build.VERSION.SDK_INT >= 35) {
            val result = intent.getParcelableExtra(Intent.EXTRA_CHOOSER_RESULT, android.service.chooser.ChooserResult::class.java)
            if (result?.type == android.service.chooser.ChooserResult.CHOOSER_RESULT_COPY) return ShareApp.OTHER
            result?.selectedComponent?.let { return EngageShare.appFor(it.packageName) }
        }
        val component: ComponentName = intent.getParcelableExtra(Intent.EXTRA_CHOSEN_COMPONENT) ?: return null
        return EngageShare.appFor(component.packageName)
    }
}
