package com.clikgate

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Spec 0.4 / 20: the core SDK contains no leaderboard, referral-stats, link-creation, code, share
 * or identity-signal API (those live in the Engage add-on), and never depends on Engage.
 * Checked against the public-API snapshot `api/clikgate.api` (kept current by `apiCheck`).
 */
class CoreBoundaryTest {
    private val forbidden = listOf(
        "leaderboard", "createlink", "mystats", "referrallink", "referralstats", "redeem", "redemption",
        "redeemedcode", "share", "whatsapp", "identitysignal", "identity_signal", "myrank", "hostedpage",
    )

    /** Feature-switch keys are allowed: they name server features, not SDK calls. */
    private val allowed = listOf(
        "public static final field LEADERBOARDS Ljava/lang/String;",
        "public static final field WHATSAPP_ATTRIBUTION Ljava/lang/String;",
    )

    private fun apiFile(): File {
        val dir = File(System.getProperty("user.dir") ?: ".")
        return listOf(File(dir, "api/clikgate.api"), File(dir, "clikgate/api/clikgate.api")).first { it.isFile }
    }

    @Test
    fun publicApiHasNoEngageFeatures() {
        val violations = apiFile().readLines()
            .map { it.trim() }
            .filter { line -> line !in allowed && forbidden.any { line.lowercase().contains(it) } }
        assertEquals("Engage-only API in core (move it to clikgate-engage):\n" + violations.joinToString("\n"), emptyList<String>(), violations)
    }

    @Test
    fun snapshotListsTheCoreFacade() {
        val api = apiFile().readText()
        assertTrue(api.contains("public final class com/clikgate/Clikgate {"))
        assertTrue(api.contains("public static final fun applyCode"))
        assertTrue(api.contains("public static final fun referredBy"))
        assertTrue(api.contains("public static final fun requestContext"))
    }

    @Test
    fun engageIsNotOnCoreClasspath() {
        for (name in listOf("com.clikgate.engage.ClikgateEngage", "com.clikgate.engage.BuildConfig")) {
            val found = try {
                Class.forName(name)
                true
            } catch (_: ClassNotFoundException) {
                false
            }
            assertTrue("$name must not be on the core classpath", !found)
        }
    }
}
