package com.clikgate

import com.clikgate.FakeApi.Companion.ok
import com.clikgate.internal.AttestationProvider
import com.clikgate.internal.AttestationToken
import okhttp3.mockwebserver.MockResponse
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.CopyOnWriteArrayList

@RunWith(RobolectricTestRunner::class)
class AttestationTest {
    private lateinit var env: TestEnv
    private val nonces = CopyOnWriteArrayList<String>()
    private val projects = CopyOnWriteArrayList<Long>()
    private val nonce = "q2mQyTw6nT1w0Yb7oX3k9yG6JmQe2l8WvK1pZ4sR0aU" // base64url, 32 bytes

    private val provider = object : AttestationProvider {
        override val type = "play_integrity"
        override fun isAvailable() = true
        override fun token(nonce: String, cloudProjectNumber: Long?, callback: (AttestationToken?) -> Unit) {
            nonces.add(nonce)
            projects.add(cloudProjectNumber ?: -1)
            callback(AttestationToken("integrity-token", if (cloudProjectNumber != null) "standard" else "classic"))
        }
    }

    @Before fun setUp() {
        env = TestEnv()
        env.attestation = provider
        env.api.on("GET /v1/sdk/config", ok(Fixtures.text("config_response").replace("\"android_play_integrity\": \"off\"", "\"android_play_integrity\": \"monitor\"")))
        env.api.on("POST /v1/sdk/attest/challenge", ok("""{"challenge":"atc_01JAB3C4D5E6F7G8H9JKMNPQRS","nonce":"$nonce","expires_at":"2026-10-20T10:05:00Z"}"""))
    }

    @After fun tearDown() = env.tearDown()

    private fun options() = env.options().copy(attestation = Attestation.PLAY_INTEGRITY_IF_AVAILABLE)

    @Test
    fun installCarriesPlayIntegrityTokenForServerNonce() {
        env.configure(options())
        eventually { env.storage.installDone }
        assertEquals(listOf(nonce), nonces) // nonce passed exactly as received
        val att = env.api.body(env.api.calls("POST /v1/sdk/install").single()).getJSONObject("attestation")
        assertEquals("play_integrity", att.getString("type"))
        assertEquals("integrity-token", att.getString("token"))
        assertEquals("atc_01JAB3C4D5E6F7G8H9JKMNPQRS", att.getString("challenge"))
        assertTrue(env.storage.lastAttestedAt > 0)
    }

    @Test
    fun retriesDoNotReuseTheSingleUseChallenge() {
        env.api.on("POST /v1/sdk/install", MockResponse().setResponseCode(503), ok(Fixtures.text("install_response_organic")))
        env.configure(options())
        eventually { env.storage.installDone }
        val calls = env.api.calls("POST /v1/sdk/install")
        assertEquals(2, calls.size)
        assertTrue(env.api.body(calls[0]).has("attestation"))
        assertFalse(env.api.body(calls[1]).has("attestation"))
        assertEquals(0L, env.storage.lastAttestedAt) // re-attested later via /attest
    }

    @Test
    fun disabledServerSideOrByOptionMeansNoAttestation() {
        env.configure() // option OFF
        eventually { env.storage.installDone }
        assertTrue(nonces.isEmpty())
        assertTrue(env.api.calls("POST /v1/sdk/attest/challenge").isEmpty())
        assertFalse(env.api.body(env.api.calls("POST /v1/sdk/install").single()).has("attestation"))
    }

    @Test
    fun weeklyReattestationUsesAttestEndpoint() {
        env.api.on("POST /v1/sdk/attest", ok("""{"attestation_status":"valid"}"""))
        var now = 1_000_000_000L
        env.configure(options(), clock = { now })
        eventually { env.storage.installDone }
        now += 8L * 24 * 3600 * 1000
        env.relaunch(options(), clock = { now })
        eventually { env.api.calls("POST /v1/sdk/attest").size == 1 }
        val body = env.api.body(env.api.calls("POST /v1/sdk/attest").single())
        assertEquals("play_integrity", body.getString("type"))
        assertEquals("atc_01JAB3C4D5E6F7G8H9JKMNPQRS", body.getString("challenge"))
        assertTrue(body.isNull("key_id"))
        eventually { env.storage.lastAttestedAt == now }
    }
}
