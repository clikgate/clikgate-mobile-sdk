package com.clikgate.internal

import android.content.Context
import android.content.pm.PackageManager
import android.hardware.display.DisplayManager
import android.os.Build
import android.util.DisplayMetrics
import android.view.Display
import org.json.JSONObject
import java.io.File
import java.util.Locale
import java.util.TimeZone

/** Device / app facts sent on `/install` and `/open`. */
internal open class DeviceInfo(private val context: Context) {

    open val appVersion: String by lazy {
        try {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "unknown"
        } catch (_: Exception) {
            "unknown"
        }
    }

    /**
     * The host app is a debug build (`FLAG_DEBUGGABLE`): the private-mode warning and the "isn't set up" goal line
     * only show there.
     */
    open val isDebuggableApp: Boolean by lazy {
        try {
            context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0
        } catch (_: Exception) {
            false
        }
    }

    open val osVersion: String get() = Build.VERSION.RELEASE ?: Build.VERSION.SDK_INT.toString()

    open val deviceModel: String? get() = Build.MODEL?.take(60)

    open val locale: String get() = Locale.getDefault().toLanguageTag()

    open val timezone: String get() = TimeZone.getDefault().id

    /** Physical screen size in pixels and density. */
    open fun screen(): JSONObject? = try {
        val metrics = DisplayMetrics()
        val dm = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        @Suppress("DEPRECATION")
        dm.getDisplay(Display.DEFAULT_DISPLAY)?.getRealMetrics(metrics)
        if (metrics.widthPixels <= 0) {
            val m = context.resources.displayMetrics
            metrics.widthPixels = m.widthPixels
            metrics.heightPixels = m.heightPixels
            metrics.density = m.density
        }
        JSONObject().apply {
            put("w", metrics.widthPixels)
            put("h", metrics.heightPixels)
            put("scale", metrics.density.toDouble())
        }
    } catch (_: Exception) {
        null
    }

    /** Installing store: `getInstallSourceInfo` on API 30+, `getInstallerPackageName` below. */
    open fun installerPackage(): String? = try {
        val pm = context.packageManager
        if (Build.VERSION.SDK_INT >= 30) {
            pm.getInstallSourceInfo(context.packageName).installingPackageName
        } else {
            @Suppress("DEPRECATION")
            pm.getInstallerPackageName(context.packageName)
        }
    } catch (_: PackageManager.NameNotFoundException) {
        null
    } catch (_: Exception) {
        null
    }

    open fun isEmulator(): Boolean = Emulator.isEmulator(
        fingerprint = Build.FINGERPRINT.orEmpty(),
        model = Build.MODEL.orEmpty(),
        manufacturer = Build.MANUFACTURER.orEmpty(),
        brand = Build.BRAND.orEmpty(),
        device = Build.DEVICE.orEmpty(),
        product = Build.PRODUCT.orEmpty(),
        hardware = Build.HARDWARE.orEmpty(),
    )

    /**
     * Root heuristic (fraud hint, not proof). No permission or `<queries>` entry is needed: su paths
     * are plain `File.exists()` checks, and root-manager packages are looked up only below API 30,
     * where package visibility filtering doesn't exist.
     */
    open fun isRooted(): Boolean = Root.isRooted(
        buildTags = Build.TAGS,
        sdkInt = Build.VERSION.SDK_INT,
        fileExists = { File(it).exists() },
        packageInstalled = { pkg ->
            try {
                @Suppress("DEPRECATION")
                context.packageManager.getPackageInfo(pkg, 0)
                true
            } catch (_: PackageManager.NameNotFoundException) {
                false
            }
        },
    )
}

/** Build-property heuristics for emulators (AOSP emulator, Genymotion, common x86 images). */
internal object Emulator {
    fun isEmulator(
        fingerprint: String,
        model: String,
        manufacturer: String,
        brand: String,
        device: String,
        product: String,
        hardware: String,
    ): Boolean {
        val fp = fingerprint.lowercase()
        val p = product.lowercase()
        val hw = hardware.lowercase()
        return fp.startsWith("generic") ||
            fp.startsWith("unknown") ||
            fp.contains("emulator") ||
            fp.contains("/sdk_gphone") ||
            model.contains("google_sdk") ||
            model.contains("Emulator") ||
            model.contains("Android SDK built for") ||
            model.startsWith("sdk_gphone") ||
            manufacturer.contains("Genymotion") ||
            (brand.startsWith("generic") && device.startsWith("generic")) ||
            hw == "goldfish" || hw == "ranchu" || hw.contains("vbox86") ||
            p == "google_sdk" || p.startsWith("sdk_") || p.contains("emulator") ||
            p.contains("simulator") || p.contains("vbox86p")
    }
}

/**
 * Rooted-device heuristics: `test-keys` build tags, an `su` binary in a common path, or (API < 30
 * only) a known root-manager app. The probes are parameters so tests don't depend on the host.
 */
internal object Root {
    val SU_PATHS = listOf(
        "/system/bin/su", "/system/xbin/su", "/sbin/su", "/system/su", "/system/sbin/su",
        "/vendor/bin/su", "/su/bin/su", "/data/local/su", "/data/local/bin/su", "/data/local/xbin/su",
        "/system/bin/.ext/.su", "/system/usr/we-need-root/su", "/system/app/Superuser.apk",
    )

    val ROOT_PACKAGES = listOf(
        "com.topjohnwu.magisk", "eu.chainfire.supersu", "com.noshufou.android.su",
        "com.noshufou.android.su.elite", "com.koushikdutta.superuser", "com.thirdparty.superuser",
        "com.yellowes.su", "com.kingroot.kinguser", "com.kingo.root", "com.smedialink.oneclickroot",
        "com.zhiqupk.root.global", "com.alephzain.framaroot",
    )

    /** Package visibility filtering (Android 11): other apps are hidden without `<queries>`. */
    const val PACKAGE_VISIBILITY_SDK = 30

    fun isRooted(
        buildTags: String?,
        sdkInt: Int,
        fileExists: (String) -> Boolean,
        packageInstalled: (String) -> Boolean,
    ): Boolean =
        buildTags?.contains("test-keys") == true ||
            SU_PATHS.any(fileExists) ||
            (sdkInt < PACKAGE_VISIBILITY_SDK && ROOT_PACKAGES.any(packageInstalled))
}
