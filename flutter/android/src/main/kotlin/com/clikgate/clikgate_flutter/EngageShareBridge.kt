package com.clikgate.clikgate_flutter

import android.app.Activity
import android.content.Context
import com.clikgate.ClikgateError
import com.clikgate.engage.ClikgateEngage
import com.clikgate.engage.ReferralLink
import com.clikgate.engage.ShareApp
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The Engage features' native side (`package:clikgate_flutter/engage.dart`): only `share.link` /
 * `share.referralLink`, which need the phone's share menu. It forwards to the native SDK's Engage
 * features (com.clikgate.engage in com.clikgate:clikgate-android), which give each app its own version
 * of the link and record the share. Everything else in Engage is Dart. Registered by ClikgateFlutterPlugin.
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
        if (call.method != "shareLink") return result.notImplemented()
        val ctx: Context = activity ?: context ?: return result.error(ClikgateError.NOT_CONFIGURED, "Plugin not attached", null)
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

    private companion object {
        const val CHANNEL = "com.clikgate/engage"
    }
}
