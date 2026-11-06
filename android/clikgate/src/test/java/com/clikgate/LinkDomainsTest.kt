package com.clikgate

import android.content.Intent
import android.net.Uri
import com.clikgate.FakeApi.Companion.error
import com.clikgate.FakeApi.Companion.ok
import com.clikgate.internal.SdkConfig
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.shadows.ShadowLog

/** Connected domains (backend Part 3 §31.3): `config.link_domains` ∪ `options.linkDomains`. */
@RunWith(RobolectricTestRunner::class)
class LinkDomainsTest {
    private lateinit var env: TestEnv

    @Before fun setUp() {
        env = TestEnv()
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_matched")))
        ShadowLog.clear()
    }

    @After fun tearDown() = env.tearDown()

    private fun configWithDomains(domains: Any?): String {
        val o = Fixtures.json("config_response")
        if (domains == null) o.remove("link_domains") else o.put("link_domains", domains)
        return o.toString()
    }

    private fun view(url: String) = Intent(Intent.ACTION_VIEW, Uri.parse(url))

    private fun installed(options: ClikgateOptions = env.options("go.yourbrand.com")) {
        env.configure(options)
        eventually { env.storage.installDone }
    }

    // ---------------------------------------------------------------- parsing

    @Test
    fun parsesPresentAbsentAndMalformedLinkDomains() {
        assertEquals(setOf("inv.myapp.com", "ciz.to"), SdkConfig.parse(Fixtures.json("config_response")).linkDomains)

        // Older server: no field. Still valid against the contract schema.
        SchemaCheck.assertValid("config_response", Fixtures.json("config_response_legacy"))
        assertEquals(emptySet<String>(), SdkConfig.parse(Fixtures.json("config_response_legacy")).linkDomains)

        // Malformed: not an array → ignored; non-strings and empty strings dropped; normalised.
        assertEquals(emptySet<String>(), SdkConfig.parse(JSONObject().put("link_domains", "ybr.ng")).linkDomains)
        assertEquals(emptySet<String>(), SdkConfig.parse(JSONObject().put("link_domains", JSONObject.NULL)).linkDomains)
        val mixed = JSONArray().put(" YBR.ng ").put(5).put(JSONObject.NULL).put("").put(JSONObject()).put("https://Go.YourBrand.com/x")
        assertEquals(setOf("ybr.ng", "go.yourbrand.com"), SdkConfig.parse(JSONObject().put("link_domains", mixed)).linkDomains)
    }

    @Test
    fun normalizeDomain() {
        assertEquals("inv.myapp.com", SdkConfig.normalizeDomain(" https://Inv.MyApp.com/path "))
        assertEquals("ybr.ng", SdkConfig.normalizeDomain("YBR.NG"))
    }

    // ---------------------------------------------------------------- matching

    @Test
    fun serverAliasDomainsAreMatchedCaseInsensitively() {
        env.api.on("GET /v1/sdk/config", ok(configWithDomains(JSONArray().put("YBR.ng").put("go.yourbrand.com"))))
        installed()
        eventually { "ybr.ng" in env.core().linkDomains }
        assertTrue(Clikgate.handleIntent(null, view("https://Ybr.NG/a8K2")))
        assertTrue(Clikgate.handleIntent(null, view("https://GO.yourbrand.com/a8K2")))
        assertFalse(Clikgate.handleIntent(null, view("https://sub.ybr.ng/a8K2")))
        eventually { env.api.calls("POST /v1/sdk/resolve").size == 2 }
    }

    @Test
    fun configuredDomainsAlwaysCountWhenServerListsNoneOrOthers() {
        env.api.on("GET /v1/sdk/config", ok(configWithDomains(null)))
        installed(env.options("Go.YourBrand.com"))
        assertEquals(setOf("go.yourbrand.com"), env.core().linkDomains)
        assertTrue(Clikgate.handleIntent(null, view("https://go.yourbrand.com/a8K2")))

        env.api.on("GET /v1/sdk/config", ok(configWithDomains(JSONArray().put("ybr.ng"))))
        env.storage.configFetchedAt = 0
        env.relaunch(env.options("go.yourbrand.com"))
        eventually { "ybr.ng" in env.core().linkDomains }
        assertTrue(Clikgate.handleIntent(null, view("https://go.yourbrand.com/a8K2")))
    }

    @Test
    fun serverDomainsArePersistedWithTheConfigCache() {
        env.api.on("GET /v1/sdk/config", ok(configWithDomains(JSONArray().put("ybr.ng"))))
        installed()
        eventually { "ybr.ng" in env.core().linkDomains }
        // Relaunch offline: the cached config is read synchronously at start-up.
        env.api.on("GET /v1/sdk/config", error(503, "{}"))
        env.relaunch(env.options("go.yourbrand.com"))
        assertTrue("ybr.ng" in env.core().linkDomains)
        assertTrue(Clikgate.handleIntent(null, view("https://ybr.ng/a8K2")))
    }

    // ---------------------------------------------------------------- warning

    @Test
    fun warnsOnceAboutServerDomainsMissingFromOptions() {
        env.api.on("GET /v1/sdk/config", ok(configWithDomains(JSONArray().put("ybr.ng").put("go.yourbrand.com"))))
        installed(env.options("go.yourbrand.com").copy(logLevel = LogLevel.WARN))
        eventually { "ybr.ng" in env.core().linkDomains }
        settle(200)
        val warnings = ShadowLog.getLogsForTag("Clikgate").map { it.msg }.filter { "not in ClikgateOptions.linkDomains" in it }
        assertEquals(1, warnings.size)
        assertTrue(warnings.single().contains("ybr.ng"))
        assertTrue(warnings.single().contains("intent filter"))
    }
}
