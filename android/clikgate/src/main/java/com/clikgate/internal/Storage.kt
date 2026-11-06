package com.clikgate.internal

import android.content.Context
import android.content.SharedPreferences
import java.util.UUID

/** Persistent SDK state in SharedPreferences `clikgate.prefs` (excluded from backup). */
internal class Storage(context: Context) {
    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /** Returns the installation id, creating (and persisting) a UUIDv4 on first use. */
    @Synchronized
    fun installationId(): String {
        prefs.getString(K_INSTALLATION_ID, null)?.let { return it }
        val id = UUID.randomUUID().toString().lowercase()
        prefs.edit().putString(K_INSTALLATION_ID, id).commit()
        return id
    }

    var installId: String?
        get() = prefs.getString(K_INSTALL_ID, null)
        set(v) = put(K_INSTALL_ID, v)

    var installDone: Boolean
        get() = prefs.getBoolean(K_INSTALL_DONE, false)
        set(v) = prefs.edit().putBoolean(K_INSTALL_DONE, v).apply()

    /** Raw `attribution` object from the last `/install` response. */
    var attributionJson: String?
        get() = prefs.getString(K_ATTRIBUTION, null)
        set(v) = put(K_ATTRIBUTION, v)

    var referrerDone: Boolean
        get() = prefs.getBoolean(K_REFERRER_DONE, false)
        set(v) = prefs.edit().putBoolean(K_REFERRER_DONE, v).apply()

    /** Install referrer details as the `install_referrer` JSON object (null = none). */
    var referrerJson: String?
        get() = prefs.getString(K_REFERRER, null)
        set(v) = put(K_REFERRER, v)

    var configJson: String?
        get() = prefs.getString(K_CONFIG, null)
        set(v) = put(K_CONFIG, v)

    var configFetchedAt: Long
        get() = prefs.getLong(K_CONFIG_AT, 0)
        set(v) = prefs.edit().putLong(K_CONFIG_AT, v).apply()

    var pushToken: String?
        get() = prefs.getString(K_PUSH_TOKEN, null)
        set(v) = put(K_PUSH_TOKEN, v)

    var pushProvider: String?
        get() = prefs.getString(K_PUSH_PROVIDER, null)
        set(v) = put(K_PUSH_PROVIDER, v)

    /** SHA-256 of provider + token of the last successful send. */
    var pushSentHash: String?
        get() = prefs.getString(K_PUSH_SENT_HASH, null)
        set(v) = put(K_PUSH_SENT_HASH, v)

    var customerUserId: String?
        get() = prefs.getString(K_USER_ID, null)
        set(v) = put(K_USER_ID, v)

    var identityToken: String?
        get() = prefs.getString(K_IDENTITY_TOKEN, null)
        set(v) = put(K_IDENTITY_TOKEN, v)

    /** True while the stored identity hasn't been sent to `/identify` yet. */
    /** A label from identifyUser() not sent yet ("" clears it on the server). */
    var pendingLabel: String?
        get() = prefs.getString(K_PENDING_LABEL, null)
        set(v) = put(K_PENDING_LABEL, v)

    var identifyPending: Boolean
        get() = prefs.getBoolean(K_IDENTIFY_PENDING, false)
        set(v) = prefs.edit().putBoolean(K_IDENTIFY_PENDING, v).apply()

    var trackingEnabled: Boolean
        get() = prefs.getBoolean(K_TRACKING, true)
        set(v) = prefs.edit().putBoolean(K_TRACKING, v).apply()

    /** Pending `/opt-out` value not yet acknowledged by the server: "true", "false" or null. */
    var pendingOptOut: Boolean?
        get() = if (prefs.contains(K_PENDING_OPT_OUT)) prefs.getBoolean(K_PENDING_OPT_OUT, true) else null
        set(v) {
            if (v == null) prefs.edit().remove(K_PENDING_OPT_OUT).apply()
            else prefs.edit().putBoolean(K_PENDING_OPT_OUT, v).apply()
        }

    var lastOpenAt: Long
        get() = prefs.getLong(K_LAST_OPEN, 0)
        set(v) = prefs.edit().putLong(K_LAST_OPEN, v).apply()

    var lastBackgroundAt: Long
        get() = prefs.getLong(K_LAST_BACKGROUND, 0)
        set(v) = prefs.edit().putLong(K_LAST_BACKGROUND, v).apply()

    var lastAttestedAt: Long
        get() = prefs.getLong(K_LAST_ATTESTED, 0)
        set(v) = prefs.edit().putLong(K_LAST_ATTESTED, v).apply()

    // ---- consent ----

    /** [ConsentValues] as JSON (purposes, updated_at, region hint); null = never set. */
    var consentJson: String?
        get() = prefs.getString(K_CONSENT, null)
        set(v) = put(K_CONSENT, v)

    /** True while a `/consent` record hasn't been acknowledged. */
    var consentSendPending: Boolean
        get() = prefs.getBoolean(K_CONSENT_PENDING, false)
        set(v) = prefs.edit().putBoolean(K_CONSENT_PENDING, v).apply()

    /** When buffering for consent started (0 = not buffering). */
    var consentPendingSince: Long
        get() = prefs.getLong(K_CONSENT_SINCE, 0)
        set(v) = prefs.edit().putLong(K_CONSENT_SINCE, v).apply()

    var installPingSent: Boolean
        get() = prefs.getBoolean(K_INSTALL_PING, false)
        set(v) = prefs.edit().putBoolean(K_INSTALL_PING, v).apply()

    /** Latest `{click_id, link_id}` of a matched deep link (attributionMetadata). */
    var lastClickJson: String?
        get() = prefs.getString(K_LAST_CLICK, null)
        set(v) = put(K_LAST_CLICK, v)

    /** Last app instance id the server acknowledged. */
    var appInstanceIdSent: String?
        get() = prefs.getString(K_APP_INSTANCE_ID, null)
        set(v) = put(K_APP_INSTANCE_ID, v)

    var firebaseAttributionLogged: Boolean
        get() = prefs.getBoolean(K_FIREBASE_LOGGED, false)
        set(v) = prefs.edit().putBoolean(K_FIREBASE_LOGGED, v).apply()

    private fun put(key: String, v: String?) {
        if (v == null) prefs.edit().remove(key).apply() else prefs.edit().putString(key, v).apply()
    }

    companion object {
        const val PREFS_NAME = "clikgate.prefs"
        private const val K_INSTALLATION_ID = "installation_id"
        private const val K_INSTALL_ID = "install_id"
        private const val K_INSTALL_DONE = "install_done"
        private const val K_ATTRIBUTION = "attribution"
        private const val K_REFERRER_DONE = "install_referrer_done"
        private const val K_REFERRER = "install_referrer"
        private const val K_CONFIG = "config"
        private const val K_CONFIG_AT = "config_fetched_at"
        private const val K_PUSH_TOKEN = "push_token"
        private const val K_PUSH_PROVIDER = "push_provider"
        private const val K_PUSH_SENT_HASH = "push_sent_hash"
        private const val K_USER_ID = "customer_user_id"
        private const val K_IDENTITY_TOKEN = "identity_token"
        private const val K_IDENTIFY_PENDING = "identify_pending"
        private const val K_PENDING_LABEL = "pending_label"
        private const val K_TRACKING = "tracking_enabled"
        private const val K_PENDING_OPT_OUT = "pending_opt_out"
        private const val K_LAST_OPEN = "last_open_at"
        private const val K_LAST_BACKGROUND = "last_background_at"
        private const val K_LAST_ATTESTED = "last_attested_at"
        private const val K_CONSENT = "consent"
        private const val K_CONSENT_PENDING = "consent_send_pending"
        private const val K_CONSENT_SINCE = "consent_pending_since"
        private const val K_INSTALL_PING = "install_ping_sent"
        private const val K_LAST_CLICK = "last_click"
        private const val K_APP_INSTANCE_ID = "app_instance_id_sent"
        private const val K_FIREBASE_LOGGED = "firebase_attribution_logged"
    }
}
