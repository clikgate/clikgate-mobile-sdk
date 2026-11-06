package com.clikgate.sample

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.clikgate.Clikgate
import com.clikgate.ClikgateDeepLink
import com.clikgate.ClikgateError
import com.clikgate.ClikgateMoney
import com.clikgate.ClikgateResult
import com.clikgate.ConsentState
import com.clikgate.Provider
import com.clikgate.engage.ClikgateEngage
import com.clikgate.engage.ShareApp

class MainActivity : Activity() {
    private lateinit var status: TextView
    private lateinit var banner: TextView
    private lateinit var log: TextView
    private val programId = BuildConfig.CLIKGATE_PROGRAM_ID
    private val deepLinkListener: (ClikgateDeepLink) -> Unit = { show("Deep link: ${describe(it)}") }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(buildUi())
        // App Links / scheme links that started the activity.
        Clikgate.handleIntent(this, intent)
        SampleApp.listeners.add(deepLinkListener)
        SampleApp.lastDeepLink?.let { show("Deep link: ${describe(it)}") }

        Clikgate.attribution { a ->
            status.text = "Attribution: ${a.status}" + (a.matchType?.let { " via $it" } ?: "") +
                (a.installId?.let { "\ninstall: $it" } ?: "")
        }
        refreshReferredBy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        Clikgate.handleIntent(this, intent) // warm start
    }

    override fun onDestroy() {
        SampleApp.listeners.remove(deepLinkListener)
        super.onDestroy()
    }

    private fun refreshReferredBy() {
        Clikgate.referrals.referredBy { result ->
            when (result) {
                is ClikgateResult.Success -> {
                    val r = result.value.referral
                    banner.visibility = if (result.value.referred && r != null) View.VISIBLE else View.GONE
                    banner.text = "Invited by ${r?.referrerDisplayName ?: "a friend"} (${r?.status})"
                }
                is ClikgateResult.Failure -> show("referredBy: ${result.error.code}")
            }
        }
    }

    private fun buildUi(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(40, 40, 40, 40)
        }
        status = TextView(this).apply { text = "Attribution: …"; textSize = 16f }
        banner = TextView(this).apply {
            visibility = View.GONE
            setPadding(24, 24, 24, 24)
            setBackgroundColor(0xFFE8F5E9.toInt())
        }
        root.addView(status)
        root.addView(banner)

        val userId = EditText(this).apply { hint = "Customer user id (e.g. user_42)" }
        val token = EditText(this).apply { hint = "Identity token from your backend (optional)" }
        root.addView(userId)
        root.addView(token)
        root.addView(button("Identify") {
            Clikgate.identifyUser(label = userId.text.toString().ifBlank { null }?.let { "Customer $it" }, customerId = userId.text.toString().ifBlank { null }, identityToken = token.text.toString().ifBlank { null })
            show("identifyUser sent")
        })

        // Invite link + stats use the optional Engage add-on (no backend). Apps with a backend should
        // get the link and stats from their server (Clikgate control-plane API) instead.
        // share.referralLink gives each app its own version of the link, so Clikgate knows where it was shared.
        root.addView(button("Share invite link") {
            ClikgateEngage.referrals.createLink(programId) { r ->
                when (r) {
                    is ClikgateResult.Success -> {
                        try {
                            ClikgateEngage.share.referralLink(this, r.value, "Join me on Clikgate Sample:")
                        } catch (e: ClikgateError) {
                            show("share: ${e.code}")
                        }
                    }
                    is ClikgateResult.Failure -> show("createLink: ${r.error.code} ${r.error.message}")
                }
            }
        })
        root.addView(button("Share invite link (WhatsApp)") {
            ClikgateEngage.referrals.createLink(programId) { r ->
                when (r) {
                    is ClikgateResult.Success -> {
                        try {
                            val viaWhatsApp = ClikgateEngage.share.referralLink(this, r.value, "Join me on Clikgate Sample:", ShareApp.WHATSAPP)
                            show(if (viaWhatsApp) "Shared to WhatsApp" else "Shared via the share sheet")
                        } catch (e: ClikgateError) {
                            show("share: ${e.code}")
                        }
                    }
                    is ClikgateResult.Failure -> show("createLink: ${r.error.code} ${r.error.message}")
                }
            }
        })
        root.addView(button("My referral stats") {
            ClikgateEngage.referrals.myStats(programId) { r ->
                show(
                    when (r) {
                        is ClikgateResult.Success -> r.value.let { "Code ${it.code}: ${it.clicks} clicks, ${it.installs} installs, ${it.qualified} qualified" }
                        is ClikgateResult.Failure -> "myStats: ${r.error.code}"
                    },
                )
            }
        })

        val code = EditText(this).apply { hint = "Friend's referral code" }
        root.addView(code)
        root.addView(button("Apply code") {
            Clikgate.referrals.applyCode(programId, code.text.toString()) { r ->
                when (r) {
                    is ClikgateResult.Success -> { show("Referral ${r.value.status}"); refreshReferredBy() }
                    is ClikgateResult.Failure -> show("applyCode: ${r.error.code}") // e.g. code_not_found
                }
            }
        })

        root.addView(button("Track purchase ₦15,000") {
            Clikgate.track("purchase", ClikgateMoney.ofMinor(1_500_000, "NGN"), mapOf("order_id" to "A-1001"))
            show("purchase tracked")
        })
        // A Standard goal, with the business's own reference (never customer data).
        root.addView(button("Goal: account opened ₦2,000,000") {
            Clikgate.goal(
                "account_opened",
                value = java.math.BigDecimal("2000000"),
                currency = "NGN",
                reference = "APP-55231",
                isFirst = true,
            ) { result -> show("account_opened: ${result.status} ${result.reason ?: ""}") }
        })
        // A Payment goal: the provider's reference from the checkout's success callback. It waits until
        // your payment provider or server confirms it, with the real amount.
        root.addView(button("Goal: purchase paid with Paystack") {
            Clikgate.goal("purchase", reference = "T123456", provider = Provider.PAYSTACK) { result ->
                show("purchase: ${result.status} ${result.reason ?: ""}")
            }
        })
        // Change 03: consent (your own banner would call these) and sales metadata.
        root.addView(button("Consent: accept all") {
            Clikgate.setConsent(ConsentState.GRANTED, ConsentState.GRANTED, ConsentState.GRANTED, ConsentState.GRANTED)
            show("consent: ${Clikgate.getConsent()}")
        })
        root.addView(button("Consent: necessary only") {
            Clikgate.setConsent(ConsentState.DENIED, ConsentState.DENIED, ConsentState.DENIED, ConsentState.DENIED)
            show("consent: ${Clikgate.getConsent()}")
        })
        root.addView(button("Pretend the user is in the EEA") {
            Clikgate.setConsentRegion("EEA")
            show("region hint EEA; consent required = ${Clikgate.getConsent().required}")
        })
        root.addView(button("Attribution metadata (for Paystack metadata)") {
            show("attributionMetadata: ${Clikgate.attributionMetadata()}")
        })
        root.addView(button("Register FCM token") {
            (application as SampleApp).registerFcmToken { show(it) }
        })

        log = TextView(this).apply { setPadding(0, 32, 0, 0) }
        root.addView(log)
        return ScrollView(this).apply { addView(root) }
    }

    private fun button(label: String, onClick: () -> Unit) = Button(this).apply {
        text = label
        isAllCaps = false
        setOnClickListener { onClick() }
    }

    private fun show(message: String) {
        log.text = "$message\n${log.text}"
    }

    private fun describe(l: ClikgateDeepLink) =
        "${l.path} ${l.data} deferred=${l.isDeferred}" + (l.referral?.let { " referral by ${it.referrerDisplayName}" } ?: "")
}
