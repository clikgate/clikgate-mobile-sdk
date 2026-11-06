package com.clikgate.internal

import android.content.Context
import android.os.Build

/** A device attestation token and the Play Integrity request flavour that produced it. */
internal class AttestationToken(val token: String, val requestType: String)

/** Produces a device attestation token for a server nonce. Injectable (tests). */
internal interface AttestationProvider {
    /** Wire `type` sent to the API. */
    val type: String

    fun isAvailable(): Boolean

    /**
     * Calls [callback] once with the token, or null on any failure. With a [cloudProjectNumber]
     * a Play Integrity **standard** request is made (`requestHash = nonce`), else a classic one.
     */
    fun token(nonce: String, cloudProjectNumber: Long?, callback: (AttestationToken?) -> Unit)
}

/**
 * Play Integrity. Standard requests (`createStandard` → `prepareIntegrityToken`
 * with the customer's Cloud project number → `request(setRequestHash(nonce))`) when a project
 * number is known; classic requests (`IntegrityTokenRequest.setNonce`) otherwise. The library is
 * `compileOnly`: this provider is available only when the app ships
 * `com.google.android.play:integrity` itself (checked with `Class.forName`).
 */
internal class PlayIntegrityProvider(private val context: Context) : AttestationProvider {
    override val type: String = "play_integrity"

    /** Warmed-up standard token provider, kept for the process (re-prepared on failure). */
    @Volatile
    private var standardProvider: Any? = null
    @Volatile
    private var standardProject: Long? = null

    override fun isAvailable(): Boolean =
        Build.VERSION.SDK_INT >= 23 && classExists("com.google.android.play.core.integrity.IntegrityManagerFactory")

    override fun token(nonce: String, cloudProjectNumber: Long?, callback: (AttestationToken?) -> Unit) {
        if (cloudProjectNumber != null) standard(nonce, cloudProjectNumber, callback) else classic(nonce, callback)
    }

    private fun classic(nonce: String, callback: (AttestationToken?) -> Unit) {
        try {
            val manager = com.google.android.play.core.integrity.IntegrityManagerFactory.create(context.applicationContext)
            val request = com.google.android.play.core.integrity.IntegrityTokenRequest.builder().setNonce(nonce).build()
            manager.requestIntegrityToken(request)
                .addOnSuccessListener { callback(AttestationToken(it.token(), "classic")) }
                .addOnFailureListener { e ->
                    Log.w("Play Integrity token request failed: ${e.javaClass.simpleName}")
                    callback(null)
                }
        } catch (t: Throwable) {
            Log.w("Play Integrity unavailable: ${t.javaClass.simpleName}")
            callback(null)
        }
    }

    private fun standard(nonce: String, project: Long, callback: (AttestationToken?) -> Unit) {
        try {
            val cached = standardProvider as? com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenProvider
            if (cached != null && standardProject == project) {
                request(cached, nonce, callback)
                return
            }
            val manager = com.google.android.play.core.integrity.IntegrityManagerFactory.createStandard(context.applicationContext)
            val prepare = com.google.android.play.core.integrity.StandardIntegrityManager.PrepareIntegrityTokenRequest.builder()
                .setCloudProjectNumber(project)
                .build()
            manager.prepareIntegrityToken(prepare)
                .addOnSuccessListener { provider ->
                    standardProvider = provider
                    standardProject = project
                    request(provider, nonce, callback)
                }
                .addOnFailureListener { e ->
                    Log.w("Play Integrity warm-up failed: ${e.javaClass.simpleName}")
                    callback(null)
                }
        } catch (t: Throwable) {
            Log.w("Play Integrity unavailable: ${t.javaClass.simpleName}")
            callback(null)
        }
    }

    private fun request(
        provider: com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenProvider,
        nonce: String,
        callback: (AttestationToken?) -> Unit,
    ) {
        val req = com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenRequest.builder()
            .setRequestHash(nonce)
            .build()
        provider.request(req)
            .addOnSuccessListener { callback(AttestationToken(it.token(), "standard")) }
            .addOnFailureListener { e ->
                // INTEGRITY_TOKEN_PROVIDER_INVALID and friends: prepare a new provider next time.
                standardProvider = null
                Log.w("Play Integrity standard request failed: ${e.javaClass.simpleName}")
                callback(null)
            }
    }

    private fun classExists(name: String): Boolean = try {
        Class.forName(name)
        true
    } catch (_: Throwable) {
        false
    }
}
