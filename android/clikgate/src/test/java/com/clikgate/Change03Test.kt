package com.clikgate

import com.clikgate.FakeApi.Companion.ok
import com.clikgate.internal.AttestationProvider
import com.clikgate.internal.AttestationToken
import com.clikgate.internal.FirebaseAnalyticsBridge
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicLong

/** Change 03 (SDK 1.2.0): consent, click ids, version policy, Firebase, metadata, identity checks. */
@RunWith(RobolectricTestRunner::class)
class Change03Test {
    private lateinit var env: TestEnv
    private val links = CopyOnWriteArrayList<ClikgateDeepLink>()
    private val now = AtomicLong(1_792_490_280_000L) // 2026-10-20T09:58:00Z
    private val clock: () -> Long = { now.get() }

    @Before fun setUp() {
        env = TestEnv()
        Clikgate.onDeepLink { links.add(it) }
    }

    @After fun tearDown() = env.tearDown()

    private fun config(name: String, edit: JSONObject.() -> Unit = {}) =
        env.api.on("GET /v1/sdk/config", ok(Fixtures.json(name).apply(edit).toString()))

    private fun consentRequired(edit: JSONObject.() -> Unit = {}) = config("config_response_consent_required", edit)

    private fun configure() = env.configure(env.options(), clock)

    private fun installs() = env.api.calls("POST /v1/sdk/install")
    private fun body(route: String) = env.api.body(env.api.calls(route).last())

    // ------------------------------------------------------------------ consent object on every body

    @Test
    fun everyBodyCarriesConsentAndMatchesTheSchemas() {
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_matched")))
        Clikgate.setConsent(analytics = ConsentState.GRANTED, attribution = ConsentState.GRANTED)
        configure()
        eventually { env.storage.installDone }
        Clikgate.goal("purchase", reference = "A-1")
        Clikgate.identifyUser(customerId = "user_42")
        Clikgate.setPushToken("fcm-token-xyz")
        assertTrue(Clikgate.handleUrl("https://inv.myapp.com/p/dress?gclid=Cj0-abc"))
        env.core().flushBlocking(3_000)
        eventually { env.api.calls("POST /v1/sdk/resolve").isNotEmpty() && env.api.calls("POST /v1/sdk/push-token").isNotEmpty() && env.api.calls("POST /v1/sdk/identify").isNotEmpty() }

        for ((route, schema) in listOf(
            "POST /v1/sdk/install" to "install_request",
            "POST /v1/sdk/goals" to "goals_request",
            "POST /v1/sdk/identify" to "identify_request",
            "POST /v1/sdk/push-token" to "push_token_request",
            "POST /v1/sdk/resolve" to "resolve_request",
        )) {
            val b = body(route)
            SchemaCheck.assertValid(schema, b)
            val c = b.getJSONObject("consent")
            assertEquals(route, "granted", c.getString("attribution"))
            assertEquals(route, "unknown", c.getString("ad_user_data"))
            assertEquals(route, "2026-10-20T09:58:00.000Z", c.getString("updated_at"))
        }
        val resolve = body("POST /v1/sdk/resolve").getJSONObject("google_click_ids")
        assertEquals("Cj0-abc", resolve.getString("gclid"))
        assertEquals("deep_link", resolve.getString("source"))
        // Not required (fixture config: NG): the installation id header is sent on /config.
        assertNotNull(env.api.requests.first { it.path!!.startsWith("/v1/sdk/config") }.getHeader("Clikgate-Installation-Id"))
    }

    // ------------------------------------------------------------------ buffering

    @Test
    fun unknownConsentInRequiredRegionBuffersAndSendsNothingIdentifying() {
        consentRequired()
        configure()
        eventually { env.api.calls("GET /v1/sdk/config").isNotEmpty() }
        Clikgate.goal("signup")
        Clikgate.goal("purchase")
        assertTrue(Clikgate.handleUrl("https://inv.myapp.com/p/dress"))
        settle(400)
        assertTrue(installs().isEmpty())
        assertTrue(env.api.calls("POST /v1/sdk/goals").isEmpty())
        assertTrue(env.api.calls("POST /v1/sdk/resolve").isEmpty())
        assertNull(env.api.calls("GET /v1/sdk/config").first().getHeader("Clikgate-Installation-Id"))
        // The link is routed locally, the goals are buffered.
        eventually { links.size == 1 }
        assertEquals("/p/dress", links[0].path)
        assertEquals(2, env.queue.count())
        assertTrue(env.storage.consentPendingSince > 0)
        assertEquals(true, Clikgate.getConsent().required)
    }

    @Test
    fun grantFlushesTheBufferAndDoesNotRouteTwice() {
        consentRequired()
        env.api.on("POST /v1/sdk/install", ok(Fixtures.text("install_response_referral").replace("\"is_deferred\": true", "\"is_deferred\": false")))
        configure()
        eventually { env.api.calls("GET /v1/sdk/config").isNotEmpty() }
        Clikgate.handleUrl("https://inv.myapp.com/r/ADA42?gbraid=0AAA-gb")
        Clikgate.goal("signup")
        eventually { links.size == 1 && env.queue.count() == 1 }

        Clikgate.setConsent(attribution = ConsentState.GRANTED)
        eventually { env.storage.installDone }
        eventually { env.api.calls("POST /v1/sdk/goals").isNotEmpty() }
        val install = installs().single().let(env.api::body)
        assertEquals("https://inv.myapp.com/r/ADA42?gbraid=0AAA-gb", install.getString("launch_url"))
        assertEquals("0AAA-gb", install.getJSONObject("google_click_ids").getString("gbraid"))
        assertEquals("granted", install.getJSONObject("consent").getString("attribution"))
        assertEquals(0L, env.storage.consentPendingSince)
        settle(200)
        assertEquals(1, links.size) // the launch URL was already delivered locally
        // The install carried the consent: no separate /consent record needed.
        assertTrue(env.api.calls("POST /v1/sdk/consent").isEmpty())
    }

    @Test
    fun denyDropsTheBufferAndSendsOneAnonymousInstallPing() {
        consentRequired()
        env.api.on("POST /v1/sdk/install-ping", ok(Fixtures.text("install_ping_response")))
        configure()
        eventually { env.api.calls("GET /v1/sdk/config").isNotEmpty() }
        Clikgate.goal("signup")
        eventually { env.queue.count() == 1 }
        Clikgate.setConsent(attribution = ConsentState.DENIED, adUserData = ConsentState.DENIED)
        eventually { env.api.calls("POST /v1/sdk/install-ping").isNotEmpty() }
        val ping = env.api.calls("POST /v1/sdk/install-ping").single()
        assertNull(ping.getHeader("Clikgate-Installation-Id"))
        val b = env.api.body(ping)
        SchemaCheck.assertValid("install_ping_request", b)
        assertEquals("denied", b.getJSONObject("consent").getString("attribution"))
        assertEquals(0, env.queue.count())
        Clikgate.goal("purchase") // never queued while denied
        settle(300)
        assertEquals(0, env.queue.count())
        assertTrue(installs().isEmpty())
        // Relaunch: the ping is not repeated.
        env.relaunch(env.options(), clock)
        settle(400)
        assertEquals(1, env.api.calls("POST /v1/sdk/install-ping").size)
    }

    @Test
    fun withdrawalAfterInstallIsRecordedAndStopsSending() {
        consentRequired()
        env.api.on("POST /v1/sdk/consent", ok(Fixtures.text("consent_response")))
        Clikgate.setConsent(ConsentState.GRANTED, ConsentState.GRANTED, ConsentState.GRANTED, ConsentState.GRANTED)
        configure()
        eventually { env.storage.installDone }
        Clikgate.setConsent(attribution = ConsentState.DENIED)
        eventually { env.api.calls("POST /v1/sdk/consent").isNotEmpty() }
        val c = env.api.body(env.api.calls("POST /v1/sdk/consent").single())
        SchemaCheck.assertValid("consent_request", c)
        assertEquals("denied", c.getJSONObject("consent").getString("attribution"))
        Clikgate.goal("purchase")
        env.core().flushBlocking(500)
        settle(200)
        assertTrue(env.api.calls("POST /v1/sdk/goals").isEmpty())
        eventually { !env.storage.consentSendPending }
    }

    @Test
    fun bufferExpiresAfterSevenDaysAndIsCappedByCount() {
        consentRequired { getJSONObject("consent").put("buffer_max_events", 3) }
        configure()
        eventually { env.api.calls("GET /v1/sdk/config").isNotEmpty() }
        repeat(5) { Clikgate.goal("g$it") }
        eventually { env.queue.count() == 3 }
        now.addAndGet(8L * 24 * 3600 * 1000)
        Clikgate.goal("late")
        eventually { env.queue.count() == 1 }
        assertEquals("late", env.queue.peek(10).single().payload.getString("goal"))
    }

    @Test
    fun regionHintMakesConsentRequiredAndIsSentToConfig() {
        // Server says not required for the IP's country (NG); the app knows the user is in Germany.
        Clikgate.setConsentRegion("de")
        configure()
        eventually { env.api.calls("GET /v1/sdk/config").isNotEmpty() }
        settle(300)
        val cfg = env.api.requests.first { it.path!!.startsWith("/v1/sdk/config") }
        assertEquals("/v1/sdk/config?region_hint=DE", cfg.path)
        assertTrue(installs().isEmpty()) // EEA → required → buffering
        val consent = Clikgate.getConsent()
        assertEquals("DE", consent.region)
        assertEquals(true, consent.required)
        Clikgate.setConsentRegion("NG")
        eventually { env.storage.installDone }
    }

    @Test
    fun notRequiredMeansNoBufferingEvenWithUnknownConsent() {
        configure()
        eventually { env.storage.installDone }
        assertEquals(false, Clikgate.getConsent().required)
        assertEquals("unknown", env.api.body(installs().single()).getJSONObject("consent").getString("analytics"))
        assertFalse(env.api.body(installs().single()).has("screen")) // probabilistic matching off
    }

    @Test
    fun invalidRegionIsIgnored() {
        configure()
        Clikgate.setConsentRegion("Europe")
        settle(200)
        assertNull(Clikgate.getConsent().region)
    }

    // ------------------------------------------------------------------ version policy

    @Test
    fun blockedVersionSendsOnlyBasicCallsAndRoutesLinksLocally() {
        config("config_response_blocked")
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_matched")))
        Clikgate.setPushToken("fcm-token-xyz")
        configure()
        eventually { env.storage.installDone }
        val install = env.api.body(installs().single())
        assertEquals(setOf("installation_id", "app_version", "sdk_version", "platform", "launch_url", "install_referrer", "consent"), install.keys().asSequence().toSet())
        SchemaCheck.assertValid("install_request", install)
        val results = CopyOnWriteArrayList<GoalResult>()
        Clikgate.goal("purchase", reference = "A-1") { results.add(it) }
        assertTrue(Clikgate.handleUrl("https://inv.myapp.com/p/dress"))
        env.core().flushBlocking(3_000)
        eventually { links.size == 1 }
        assertNull(links[0].link) // local delivery, no /resolve
        assertTrue(env.api.calls("POST /v1/sdk/resolve").isEmpty())
        assertTrue(env.api.calls("POST /v1/sdk/push-token").isEmpty())
        // The blocked policy doesn't list `goals`: the goal is refused on the device, never sent.
        eventually { results.size == 1 }
        assertEquals(GoalStatus.REFUSED, results[0].status)
        assertEquals("sdk_version_blocked", results[0].reason)
        assertTrue(env.api.calls("POST /v1/sdk/goals").isEmpty())
        assertEquals(0, env.queue.count())
    }

    @Test
    fun deprecatedVersionKeepsWorking() {
        config("config_response_deprecated")
        configure()
        eventually { env.storage.installDone }
        assertTrue(env.api.body(installs().single()).has("device_model"))
    }

    @Test
    fun versionComparison() {
        val p = com.clikgate.internal.VersionPolicy.parse(JSONObject().put("min_supported_version", "1.2.0"))
        assertEquals("deprecated", p.effectiveStatus("1.1.9"))
        assertNull(p.effectiveStatus("1.2.0"))
        assertNull(p.effectiveStatus("1.10.0"))
        assertTrue(com.clikgate.internal.VersionPolicy.compare("1.2.0-beta.1", "1.2.0") == 0)
        val blocked = com.clikgate.internal.VersionPolicy.parse(JSONObject().put("version_status", "blocked"))
        assertTrue(blocked.allows("install"))
        assertFalse(blocked.allows("goals")) // only when the server lists it
        assertFalse(blocked.allows("events")) // Change 22: no events call
        assertFalse(blocked.allows("resolve"))
    }

    // ------------------------------------------------------------------ click ids

    @Test
    fun clickIdParsing() {
        val u = com.clikgate.internal.ClickIds.fromUrl("myapp://open?cg_click_id=clk_1&wbraid=WB1&gclid=%20")!!
        assertEquals("WB1", u.getString("wbraid"))
        assertTrue(u.isNull("gclid"))
        assertEquals("deep_link", u.getString("source"))
        assertNull(com.clikgate.internal.ClickIds.fromUrl("https://inv.myapp.com/p"))
        assertNull(com.clikgate.internal.ClickIds.fromUrl("https://inv.myapp.com/p?gclid=" + "x".repeat(513)))
        val r = com.clikgate.internal.ClickIds.fromReferrer("utm_source%3Dgoogle-play%26gclid%3DCj0_x-1%26gbraid%3Dgb")!!
        assertEquals("Cj0_x-1", r.getString("gclid"))
        assertEquals("gb", r.getString("gbraid"))
        assertEquals("install_referrer", r.getString("source"))
        assertNull(com.clikgate.internal.ClickIds.fromReferrer("utm_source=google-play"))
    }

    @Test
    fun installPrefersLaunchUrlClickIdsOverReferrer() {
        Clikgate.handleUrl("https://inv.myapp.com/p/dress?wbraid=WB9")
        configure()
        eventually { env.storage.installDone }
        val ids = env.api.body(installs().single()).getJSONObject("google_click_ids")
        assertEquals("WB9", ids.getString("wbraid"))
        assertTrue(ids.isNull("gclid"))
        assertEquals("deep_link", ids.getString("source"))
    }

    @Test
    fun openCarriesClickIdsOfTheLinkSinceLastOpen() {
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_matched")))
        configure()
        eventually { env.storage.installDone }
        Clikgate.handleUrl("https://inv.myapp.com/p/dress?gclid=G1")
        eventually { env.api.calls("POST /v1/sdk/resolve").isNotEmpty() }
        env.core().onForeground()
        env.core().onBackground()
        now.addAndGet(31L * 60 * 1000)
        env.core().onForeground()
        eventually { env.api.calls("POST /v1/sdk/open").isNotEmpty() }
        val open = body("POST /v1/sdk/open")
        SchemaCheck.assertValid("open_request", open)
        assertEquals("G1", open.getJSONObject("google_click_ids").getString("gclid"))
        assertEquals("deep_link", open.getJSONObject("google_click_ids").getString("source"))
        // Sent once: the next open has none.
        env.core().onBackground()
        now.addAndGet(31L * 60 * 1000)
        env.core().onForeground()
        eventually { env.api.calls("POST /v1/sdk/open").size == 2 }
        assertFalse(body("POST /v1/sdk/open").has("google_click_ids"))
    }

    // ------------------------------------------------------------------ attributionMetadata

    @Test
    fun attributionMetadataFromInstallThenLatestDeepLink() {
        env.api.on("POST /v1/sdk/install", ok(Fixtures.text("install_response_referral")))
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_matched")))
        assertTrue(Clikgate.attributionMetadata().isEmpty()) // before configure
        configure()
        eventually { env.storage.installDone }
        assertEquals(mapOf("cg_click_id" to "clk_01JAB3C4D5E6F7G8H9JKMNPQRS", "cg_link_id" to "lnk_01JAB3C4D5E6F7G8H9JKMNPQRS"), Clikgate.attributionMetadata())
        env.api.on("POST /v1/sdk/resolve", ok(Fixtures.text("resolve_response_matched").replace("clk_01JAB3C4D5E6F7G8H9JKMNPQRS", "clk_01JAB3C4D5E6F7G8H9JKMNPQRT")))
        Clikgate.handleUrl("https://inv.myapp.com/p/dress")
        eventually { Clikgate.attributionMetadata()["cg_click_id"] == "clk_01JAB3C4D5E6F7G8H9JKMNPQRT" }
        Clikgate.setTrackingEnabled(false)
        eventually { Clikgate.attributionMetadata().isEmpty() }
    }

    @Test
    fun attributionMetadataEmptyWithoutAttributionConsentInRequiredRegion() {
        consentRequired()
        env.api.on("POST /v1/sdk/install", ok(Fixtures.text("install_response_referral")))
        Clikgate.setConsent(attribution = ConsentState.GRANTED)
        configure()
        eventually { env.storage.installDone }
        assertFalse(Clikgate.attributionMetadata().isEmpty())
        Clikgate.setConsent(attribution = ConsentState.DENIED)
        eventually { Clikgate.attributionMetadata().isEmpty() }
    }

    // ------------------------------------------------------------------ Firebase forwarding

    private class FakeFirebase(var available: Boolean = true, var instanceId: String? = "aiid-1") : FirebaseAnalyticsBridge {
        val events = CopyOnWriteArrayList<Pair<String, Map<String, Any>>>()
        val props = CopyOnWriteArrayList<Pair<String, String>>()
        override fun isAvailable() = available
        override fun logEvent(name: String, params: Map<String, Any>) { events.add(name to params) }
        override fun setUserProperty(name: String, value: String) { props.add(name to value) }
        override fun appInstanceId(cb: (String?) -> Unit) = cb(instanceId)
    }

    private fun firebaseEnabled() = config("config_response") {
        put("firebase_forwarding", JSONObject().put("enabled", true))
    }

    @Test
    fun firebaseForwardingLogsAttributionOnceAndReportsAppInstanceId() {
        val fb = FakeFirebase()
        env.firebase = fb
        firebaseEnabled()
        env.api.on("POST /v1/sdk/install", ok(Fixtures.text("install_response_attributed_source")))
        Clikgate.enableFirebaseForwarding(FirebaseForwardingOptions())
        configure()
        eventually { fb.events.any { it.first == "clikgate_attribution" } }
        val p = fb.events.first { it.first == "clikgate_attribution" }.second
        assertEquals(mapOf("cg_source" to "google", "cg_medium" to "cpc", "cg_campaign" to "lagos_launch", "cg_channel" to "ads",
            "cg_link_id" to "lnk_01JAB3C4D5E6F7G8H9JKMNPQRS", "cg_match_type" to "app_link"), p)
        assertEquals(listOf("cg_first_source" to "google", "cg_first_campaign" to "lagos_launch"), fb.props.toList())
        assertEquals("aiid-1", env.api.body(installs().single()).getString("app_instance_id"))

        // Change 22: no event mirroring (there are no app events); goals aren't logged to Firebase.
        Clikgate.goal("signup")
        settle(200)
        assertEquals(listOf("clikgate_attribution"), fb.events.map { it.first })

        env.relaunch(env.options(), clock)
        Clikgate.enableFirebaseForwarding()
        env.core().onForeground()
        eventually { env.api.calls("POST /v1/sdk/open").isNotEmpty() }
        assertEquals(1, fb.events.count { it.first == "clikgate_attribution" }) // once per install
        assertFalse(body("POST /v1/sdk/open").has("app_instance_id")) // unchanged since install
    }

    @Test
    fun changedAppInstanceIdGoesOnTheNextOpen() {
        val fb = FakeFirebase()
        env.firebase = fb
        firebaseEnabled()
        Clikgate.enableFirebaseForwarding()
        configure()
        eventually { env.storage.installDone }
        fb.instanceId = "aiid-2"
        env.relaunch(env.options(), clock)
        Clikgate.enableFirebaseForwarding()
        env.core().onForeground()
        eventually(message = "open: " + env.api.requests.map { it.path }) { env.api.calls("POST /v1/sdk/open").isNotEmpty() }
        eventually { env.storage.appInstanceIdSent == "aiid-2" }
        assertEquals("aiid-2", body("POST /v1/sdk/open").getString("app_instance_id"))
    }

    @Test
    fun firebaseAbsentOrNotAllowedDoesNothing() {
        val fb = FakeFirebase(available = false)
        env.firebase = fb
        firebaseEnabled()
        Clikgate.enableFirebaseForwarding()
        configure()
        eventually { env.storage.installDone }
        settle(300)
        assertTrue(fb.events.isEmpty())
        assertFalse(env.api.body(installs().single()).has("app_instance_id"))
    }

    @Test
    fun firebaseNeedsServerSwitchAndAnalyticsConsent() {
        val fb = FakeFirebase()
        env.firebase = fb
        // Server switch off (fixture default).
        Clikgate.enableFirebaseForwarding()
        configure()
        eventually { env.storage.installDone }
        settle(300)
        assertTrue(fb.events.isEmpty())
        // Required region + analytics denied: nothing either.
        consentRequired()
        now.addAndGet(2L * 3600 * 1000) // cached config expires
        env.relaunch(env.options(), clock)
        Clikgate.setConsent(analytics = ConsentState.DENIED, attribution = ConsentState.GRANTED)
        Clikgate.enableFirebaseForwarding()
        env.core().onForeground()
        settle(400)
        assertTrue(fb.events.isEmpty())
    }

    // ------------------------------------------------------------------ Play Integrity flavours

    @Test
    fun playIntegrityStandardWithProjectNumberClassicWithout() {
        val seen = CopyOnWriteArrayList<Long?>()
        env.attestation = object : AttestationProvider {
            override val type = "play_integrity"
            override fun isAvailable() = true
            override fun token(nonce: String, cloudProjectNumber: Long?, callback: (AttestationToken?) -> Unit) {
                seen.add(cloudProjectNumber)
                callback(AttestationToken("t", if (cloudProjectNumber != null) "standard" else "classic"))
            }
        }
        config("config_response") { getJSONObject("features").getJSONObject("attestation").put("android_play_integrity", "monitor") }
        env.api.on("POST /v1/sdk/attest/challenge", ok("""{"challenge":"atc_01JAB3C4D5E6F7G8H9JKMNPQRS","nonce":"bm9uY2U","expires_at":"2026-10-20T10:05:00Z"}"""))
        env.configure(env.options().copy(attestation = Attestation.PLAY_INTEGRITY_IF_AVAILABLE, cloudProjectNumber = 42L), clock)
        eventually { env.storage.installDone }
        assertEquals(listOf<Long?>(42L), seen.toList())
        assertEquals("standard", env.api.body(installs().single()).getJSONObject("attestation").getString("request_type"))
    }

    @Test
    fun identityChecksNeedAnalyticsConsentUnlessFraudPreventionBasis() {
        env.attestation = object : AttestationProvider {
            override val type = "play_integrity"
            override fun isAvailable() = true
            override fun token(nonce: String, cloudProjectNumber: Long?, callback: (AttestationToken?) -> Unit) =
                callback(AttestationToken("t", "classic"))
        }
        consentRequired { getJSONObject("features").getJSONObject("attestation").put("android_play_integrity", "monitor") }
        env.api.on("POST /v1/sdk/attest/challenge", ok("""{"challenge":"atc_01JAB3C4D5E6F7G8H9JKMNPQRS","nonce":"bm9uY2U","expires_at":"2026-10-20T10:05:00Z"}"""))
        Clikgate.setConsent(analytics = ConsentState.DENIED, attribution = ConsentState.GRANTED)
        env.configure(env.options().copy(attestation = Attestation.PLAY_INTEGRITY_IF_AVAILABLE), clock)
        eventually { env.storage.installDone }
        assertFalse(env.api.body(installs().single()).has("attestation")) // basis "consent", analytics denied
    }

    // ------------------------------------------------------------------ pure logic

    @Test
    fun requiredRegionLogic() {
        val c = com.clikgate.internal.ConsentConfig.parse(Fixtures.json("config_response_consent_required").getJSONObject("consent"))!!
        val r = com.clikgate.internal.Consent
        assertEquals(true, r.required(c, null))
        assertEquals(false, r.required(c.copy(required = false), null))
        assertEquals(true, r.required(c.copy(required = false), "FR"))
        assertEquals(true, r.required(c.copy(required = false), "GB"))
        assertEquals(true, r.required(c.copy(required = false), "CH"))
        assertEquals(false, r.required(c.copy(required = true), "NG"))
        assertEquals(false, r.required(c.copy(mode = "not_required"), "DE"))
        assertEquals(true, r.required(c.copy(mode = "required_everywhere"), "NG"))
        assertNull(r.required(null, null))
        assertEquals(true, r.required(null, "NO"))
        assertEquals(false, r.required(null, "NG"))
        assertTrue(r.allowed(ConsentState.UNKNOWN, required = false))
        assertFalse(r.allowed(ConsentState.UNKNOWN, required = true))
        assertFalse(r.allowed(ConsentState.DENIED, required = false))
        assertEquals("EEA", r.normalizeRegion(" eea "))
        assertNull(r.normalizeRegion("DEU"))
    }

    @Test
    fun firebaseLimits() {
        val l = com.clikgate.internal.FirebaseLimits
        assertTrue(l.isValidName("sign_up"))
        assertFalse(l.isValidName("firebase_x"))
        assertFalse(l.isValidName("a".repeat(41)))
        val many = (1..30).associate { "p$it" to "v".repeat(150) }
        val p = l.params(many)
        assertEquals(25, p.size)
        assertEquals(100, (p["p1"] as String).length)
    }

    @Test
    fun referralCallsAndRequestContextFailWhileBufferingOrBlocked() {
        consentRequired()
        configure()
        eventually { env.api.calls("GET /v1/sdk/config").isNotEmpty() }
        val errors = CopyOnWriteArrayList<String>()
        Clikgate.referrals.referredBy { r -> errors.add(r.errorOrNull()?.code ?: "ok") }
        @OptIn(ClikgateInternalApi::class)
        Clikgate.requestContext { r -> errors.add(r.errorOrNull()?.code ?: "ok") }
        eventually { errors.size == 2 }
        assertEquals(listOf("consent_required", "consent_required"), errors.toList())
        assertTrue(env.api.calls("GET /v1/sdk/referrals/referred-by").isEmpty())
    }

    @Test
    fun referralCallsFailWhenTheVersionIsBlocked() {
        config("config_response_blocked")
        configure()
        eventually { env.storage.installDone }
        val errors = CopyOnWriteArrayList<String>()
        Clikgate.referrals.referredBy { r -> errors.add(r.errorOrNull()?.code ?: "ok") }
        eventually { errors.size == 1 }
        assertEquals("sdk_version_blocked", errors.single())
    }

    @Test
    fun firstConfigIsAnonymousUntilConsentRequirementIsKnown() {
        configure()
        eventually { env.storage.installDone }
        // First launch, nothing cached, attribution not granted: no installation id on the first /config.
        assertNull(env.api.calls("GET /v1/sdk/config").first().getHeader("Clikgate-Installation-Id"))
        // /install itself carries it (not required in NG).
        assertNotNull(installs().single().getHeader("Clikgate-Installation-Id"))
    }
}
