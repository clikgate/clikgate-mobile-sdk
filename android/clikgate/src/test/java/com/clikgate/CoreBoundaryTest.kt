package com.clikgate

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Spec 0.4 / 20, kept after the merge (2.1.0): the Engage features ship in this artifact, but only under
 * `com.clikgate.engage`. The rest of the public API (the core) has no leaderboard, referral-stats,
 * link-creation, code, share or identity-signal API, and core code never uses Engage
 * (`checkNoEngageDependency`). Checked against the public-API snapshot `api/clikgate.api` (`apiCheck`).
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

    /** The snapshot's class blocks outside com/clikgate/engage (BCV: "<modifiers> class com/x/Y ... {" to "}"). */
    private fun coreLines(): List<String> {
        val out = mutableListOf<String>()
        var inEngage = false
        for (raw in apiFile().readLines()) {
            val line = raw.trim()
            if (raw.isNotEmpty() && !raw.startsWith(" ") && line.endsWith("{")) inEngage = line.contains(" com/clikgate/engage/")
            if (!inEngage) out += line
        }
        return out
    }

    @Test
    fun corePublicApiHasNoEngageFeatures() {
        val violations = coreLines().filter { line -> line !in allowed && forbidden.any { line.lowercase().contains(it) } }
        assertEquals("Engage-only API outside com.clikgate.engage (move it there):\n" + violations.joinToString("\n"), emptyList<String>(), violations)
    }

    @Test
    fun engageFeaturesShipInThisArtifact() {
        val api = apiFile().readText()
        assertTrue(api.contains("public final class com/clikgate/engage/ClikgateEngage {"))
    }

    @Test
    fun snapshotListsTheCoreFacade() {
        val api = apiFile().readText()
        assertTrue(api.contains("public final class com/clikgate/Clikgate {"))
        assertTrue(api.contains("public static final fun applyCode"))
        assertTrue(api.contains("public static final fun referredBy"))
        assertTrue(api.contains("public static final fun requestContext"))
    }
}
