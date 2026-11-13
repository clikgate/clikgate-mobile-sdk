package com.clikgate.clikgate_flutter

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import com.clikgate.ClikgateError
import com.clikgate.engage.ClikgateEngage
import com.clikgate.engage.EngageErrors
import com.clikgate.engage.ReferralLink
import com.clikgate.engage.ShareApp
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The Engage features' native side (`package:clikgate_flutter/engage.dart`), which need the phone's share
 * menu or another app. `shareLink` (`share.link` / `share.referralLink`) forwards to the native SDK's Engage
 * features (com.clikgate.engage in com.clikgate:clikgate-android), which give each app its own version
 * of the link and record the share. `shareText` (`share.system`) and `openUrl` (`share.whatsApp`'s
 * `whatsapp://` link) are plain intents here, so the plugin needs no share_plus / url_launcher.
 * Everything else in Engage is Dart. Registered by ClikgateFlutterPlugin.
 */
internal class EngageShareBridge : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private var context: Context? = null
    private var activity: Activity? = null
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivity() { activity = null }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in METHODS) return result.notImplemented()
        val ctx: Context = activity ?: context ?: return result.error(ClikgateError.NOT_CONFIGURED, "Plugin not attached", null)
        when (call.method) {
            "shareText" -> return shareText(ctx, call, result)
            "openUrl" -> return openUrl(ctx, call, result)
        }
        val url = call.argument<String>("url")
        if (url.isNullOrBlank()) return result.error(ClikgateError.INVALID_ARGUMENT, "url is required", null)
        val message = call.argument<String>("message")
        val app = call.argument<String>("app")?.let { v -> ShareApp.entries.firstOrNull { it.value == v } }
        val code = call.argument<String>("code")
        try {
            val opened = if (code != null) {
                val link = ReferralLink("", "", code, url, call.argument<String>("shortUrl") ?: "")
                ClikgateEngage.share.referralLink(ctx, link, message, app)
            } else {
                @Suppress("UNCHECKED_CAST")
                val given = (call.argument<Map<String, String>>("shareUrls") ?: emptyMap())
                    .mapNotNull { (k, v) -> ShareApp.entries.firstOrNull { it.value == k }?.let { it to v } }.toMap()
                ClikgateEngage.share.link(ctx, url, message, app, given.ifEmpty { null })
            }
            result.success(opened)
        } catch (e: ClikgateError) {
            result.error(e.code, e.message ?: e.code, null)
        }
    }

    /** `{text, subject?}`: the system share sheet (`ACTION_SEND` text/plain in a chooser); `share_unavailable` when nothing can show it. */
    private fun shareText(ctx: Context, call: MethodCall, result: MethodChannel.Result) {
        val text = call.argument<String>("text") ?: return result.error(ClikgateError.INVALID_ARGUMENT, "text is required", null)
        try {
            ctx.startActivity(shareIntent(ctx, text, call.argument<String>("subject")))
            result.success(null)
        } catch (e: ActivityNotFoundException) {
            result.error(EngageErrors.SHARE_UNAVAILABLE, "No app can share text on this device", null)
        }
    }

    /** `{url}`: opens the URL in the app that handles it (`ACTION_VIEW`); false when no app does. */
    private fun openUrl(ctx: Context, call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url.isNullOrBlank()) return result.error(ClikgateError.INVALID_ARGUMENT, "url is required", null)
        result.success(
            try {
                ctx.startActivity(viewIntent(ctx, url))
                true
            } catch (_: ActivityNotFoundException) {
                false
            },
        )
    }

    internal companion object {
        const val CHANNEL = "com.clikgate/engage"
        val METHODS = setOf("shareLink", "shareText", "openUrl")

        /** Without an Activity (app context) the chooser starts in a new task. */
        private fun newTask(ctx: Context, intent: Intent): Intent =
            if (ctx is Activity) intent else intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        fun shareIntent(ctx: Context, text: String, subject: String?): Intent {
            val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
            if (subject != null) send.putExtra(Intent.EXTRA_SUBJECT, subject)
            return newTask(ctx, Intent.createChooser(send, null))
        }

        fun viewIntent(ctx: Context, url: String): Intent = newTask(ctx, Intent(Intent.ACTION_VIEW, Uri.parse(url)))
    }
}
