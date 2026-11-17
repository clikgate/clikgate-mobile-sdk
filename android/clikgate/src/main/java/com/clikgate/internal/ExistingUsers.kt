package com.clikgate.internal

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.os.Build
import android.provider.Settings
import android.util.Base64
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * What the phone knows about when the app arrived on it, read once per
 * `/install` body. Every value is optional: a failing read leaves it null and its field out.
 */
internal data class AppInstallFacts(
    /** `PackageInfo.firstInstallTime` (ms; survives updates, reset by a reinstall). */
    val firstInstallTime: Long? = null,
    /** `PackageInfo.lastUpdateTime` (ms). */
    val lastUpdateTime: Long? = null,
    /** `PackageInfo.longVersionCode`. */
    val versionCode: Long? = null,
    /** FLAG_SYSTEM or FLAG_UPDATED_SYSTEM_APP: preloaded by the phone maker. */
    val preinstalled: Boolean = false,
    /** `Settings.Secure.ANDROID_ID` (app-scoped since Android 8). Never sent as is: only its keyed hash. */
    val androidId: String? = null,
)

/** Reads [AppInstallFacts] from the package manager (tests use a fake [DeviceInfo]). */
internal object AppInstallFactsReader {
    @SuppressLint("HardwareIds")
    fun read(context: Context): AppInstallFacts {
        val info: PackageInfo? = try {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(context.packageName, 0)
        } catch (_: Exception) {
            null
        }
        val flags = try {
            context.applicationInfo.flags
        } catch (_: Exception) {
            0
        }
        val versionCode = info?.let {
            if (Build.VERSION.SDK_INT >= 28) it.longVersionCode else @Suppress("DEPRECATION") it.versionCode.toLong()
        }
        val androidId = try {
            Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
        } catch (_: Exception) {
            null
        }
        return AppInstallFacts(
            firstInstallTime = info?.firstInstallTime?.takeIf { it > 0 },
            lastUpdateTime = info?.lastUpdateTime?.takeIf { it > 0 },
            versionCode = versionCode?.takeIf { it >= 0 },
            preinstalled = flags and (ApplicationInfo.FLAG_SYSTEM or ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0,
            androidId = androidId?.takeIf { it.isNotBlank() },
        )
    }
}

/**
 * Builds the existing-user `/install` fields. Pure: everything it needs
 * is passed in, so unit tests cover every branch without a device.
 */
internal object ExistingUserFields {
    const val HOUR_MS = 3_600_000L

    /** Two package times this close are "the same moment". */
    const val SAME_MOMENT_MS = 60_000L

    /** Installer packages that mean "installed by hand" (an APK file), not a store. */
    val SIDELOAD_INSTALLERS = setOf(
        "com.google.android.packageinstaller",
        "com.android.packageinstaller",
        "com.android.shell",
    )

    class Inputs(
        val facts: AppInstallFacts,
        val installerPackage: String?,
        val debuggable: Boolean,
        /** `install_referrer.install_begin_timestamp_server_seconds` (Google's clock), 0 when absent. */
        val playInstallBeginServerSeconds: Long,
        val nowMs: Long,
        /** `ClikgateOptions.existingUser`. */
        val hint: Boolean,
        /** Tracking consent denied or opted out: no dates, only [startAtMs] compared on the phone. */
        val datesAllowed: Boolean,
        /** `/config existing_users.start_at` (ms), null when not set yet. */
        val startAtMs: Long?,
        /** `/config existing_users.device_key_salt` (base64), null when not used. */
        val deviceKeySalt: String?,
        /**
         * `ClikgateOptions.debugPlatformInstalledAt` (ms): only used when the build is debuggable and the
         * app's key is a test (sandbox) key; ignored otherwise.
         */
        val debugInstalledAtMs: Long?,
        val testEnvironment: Boolean,
    )

    fun installChannel(installer: String?, debuggable: Boolean): String = when {
        debuggable -> "debug"
        installer.isNullOrEmpty() || installer in SIDELOAD_INSTALLERS -> "sideload"
        else -> "store"
    }

    /** The phone's install date and its source: Google's server time wins over the phone's own clock. */
    fun installedAt(i: Inputs): Pair<Long, String>? {
        val debug = i.debugInstalledAtMs
        if (debug != null && i.debuggable && i.testEnvironment) return debug to "android_first_install_time"
        if (i.playInstallBeginServerSeconds > 0) return i.playInstallBeginServerSeconds * 1000 to "play_install_begin_server"
        val first = i.facts.firstInstallTime ?: return null
        return first to "android_first_install_time"
    }

    fun put(body: JSONObject, i: Inputs) {
        body.put("install_channel", installChannel(i.installerPackage, i.debuggable))
        body.put("debuggable", i.debuggable)
        if (i.hint) body.put("existing_user_hint", true)
        val installed = installedAt(i)
        if (!i.datesAllowed) {
            // Whether the app was here before the start date, worked out on the phone; never the dates
            val start = i.startAtMs
            if (installed != null && start != null && !i.facts.preinstalled) {
                body.put("installed_before_start", installed.first < start)
            }
            if (!i.hint) body.put("existing_user_hint", false)
            return
        }
        body.put("preinstalled", i.facts.preinstalled)
        if (installed != null) {
            body.put("platform_installed_at", isoHour(installed.first))
            body.put("platform_installed_source", installed.second)
        }
        val first = i.facts.firstInstallTime
        val last = i.facts.lastUpdateTime
        if (last != null) body.put("android_last_update_at", isoHour(last))
        if (first != null && last != null) body.put("android_updated_since_install", last - first > SAME_MOMENT_MS)
        i.facts.versionCode?.let { body.put("android_version_code", it) }
        body.put("device_time", iso(i.nowMs))
        deviceKey(i.facts.androidId, i.deviceKeySalt)?.let { body.put("android_device_key", it) }
    }

    /** Hex HMAC-SHA256 of ANDROID_ID with the per-app key; null without either. */
    fun deviceKey(androidId: String?, saltBase64: String?): String? {
        if (androidId.isNullOrEmpty() || saltBase64.isNullOrEmpty()) return null
        return try {
            val key = Base64.decode(saltBase64, Base64.DEFAULT)
            if (key.isEmpty()) return null
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(key, "HmacSHA256"))
            mac.doFinal(androidId.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
        } catch (_: Exception) {
            null
        }
    }

    /** Rounded down to the hour (the server keeps the day only). */
    fun isoHour(ms: Long): String = iso(ms - Math.floorMod(ms, HOUR_MS))

    fun iso(ms: Long): String =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date(ms))

    /** Parses `/config existing_users.start_at` (ISO 8601 with `Z` or an offset, optional fraction). */
    fun parseTime(value: String?): Long? {
        if (value.isNullOrBlank()) return null
        // The RFC 822 offset (+0100) parses on every API level; the ISO 8601 one (+01:00) needs API 24, so the colon goes
        val v = value.trim().replace(Regex("\\.\\d+"), "").replace(Regex("Z$"), "+0000")
            .replace(Regex("([+-]\\d{2}):(\\d{2})$"), "$1$2")
        return try {
            SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssZ", Locale.US).parse(v)?.time
        } catch (_: Exception) {
            null
        }
    }
}
