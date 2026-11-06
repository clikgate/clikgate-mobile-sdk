package com.clikgate.sample

import android.app.Application
import android.content.Intent
import com.clikgate.Clikgate
import com.clikgate.ClikgateDeepLink
import com.clikgate.ClikgateOptions
import com.clikgate.FirebaseForwardingOptions
import com.clikgate.LogLevel
import com.clikgate.PushProvider
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging

class SampleApp : Application() {

    override fun onCreate() {
        super.onCreate()
        // Change 03: in consent regions (EEA, UK, CH by default) nothing identifying is sent until the
        // user answers your consent prompt; MainActivity has buttons that call setConsent.
        Clikgate.configure(
            this,
            sdkKey = BuildConfig.CLIKGATE_SDK_KEY,
            options = ClikgateOptions(
                linkDomains = listOf(BuildConfig.CLIKGATE_LINK_DOMAIN),
                apiBaseUrl = BuildConfig.CLIKGATE_API_BASE_URL,
                logLevel = LogLevel.DEBUG,
            ),
        )

        // Every deep link (deferred after install, or direct App Link / scheme open) arrives here.
        Clikgate.onDeepLink { link ->
            lastDeepLink = link
            listeners.forEach { it(link) }
            if (link.path?.startsWith("/products/") == true) {
                startActivity(
                    Intent(this, ProductActivity::class.java)
                        .putExtra(ProductActivity.EXTRA_PATH, link.path)
                        .putExtra(ProductActivity.EXTRA_DATA, link.data.toString())
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            }
        }

        initFirebase()
        registerFcmToken()
        // Change 03: mirror Clikgate attribution (and tracked events) into Firebase Analytics when the
        // app's Clikgate settings enable GA4 forwarding. Needs analytics consent where required.
        Clikgate.enableFirebaseForwarding(FirebaseForwardingOptions(mirrorEvents = true, eventNameMap = mapOf("purchase" to "purchase")))
    }

    /**
     * Initialises Firebase from the `clikgate.firebase*` Gradle properties when they are set
     * (the sample doesn't apply the google-services plugin, so it builds without
     * google-services.json). Without them push is skipped and everything else works.
     */
    private fun initFirebase() {
        if (FirebaseApp.getApps(this).isNotEmpty() || BuildConfig.FIREBASE_APP_ID.isEmpty()) return
        FirebaseApp.initializeApp(
            this,
            FirebaseOptions.Builder()
                .setApiKey(BuildConfig.FIREBASE_API_KEY)
                .setApplicationId(BuildConfig.FIREBASE_APP_ID)
                .setProjectId(BuildConfig.FIREBASE_PROJECT_ID)
                .setGcmSenderId(BuildConfig.FIREBASE_SENDER_ID)
                .build(),
        )
    }

    /** Forwards the FCM token for uninstall tracking. Skipped when Firebase isn't configured. */
    fun registerFcmToken(onResult: (String) -> Unit = {}) {
        if (!isFirebaseConfigured()) {
            onResult("Firebase not configured (no clikgate.firebase* properties): push skipped")
            return
        }
        FirebaseMessaging.getInstance().token
            .addOnSuccessListener { token ->
                Clikgate.setPushToken(token, PushProvider.FCM)
                onResult("FCM token registered (${token.take(8)}…)")
            }
            .addOnFailureListener { onResult("FCM token failed: ${it.message}") }
    }

    fun isFirebaseConfigured(): Boolean = FirebaseApp.getApps(this).isNotEmpty()

    companion object {
        @Volatile
        var lastDeepLink: ClikgateDeepLink? = null
        val listeners = mutableListOf<(ClikgateDeepLink) -> Unit>()
    }
}
