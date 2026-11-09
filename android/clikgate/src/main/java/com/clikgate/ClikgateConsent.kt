package com.clikgate

/** State of one consent purpose. */
public enum class ConsentState(public val wireName: String) {
    GRANTED("granted"),
    DENIED("denied"),
    UNKNOWN("unknown"),
    ;

    public companion object {
        /** The state for a contract string (`granted`, `denied`, `unknown`), or null. */
        @JvmStatic
        public fun fromWire(value: String?): ConsentState? = entries.firstOrNull { it.wireName == value }
    }
}

/**
 * The consent the app set with [Clikgate.setConsent] (all [ConsentState.UNKNOWN] until then), the
 * region hint from [Clikgate.setConsentRegion], and whether consent is required for this device
 * ([required]: null while unknown, i.e. before a config that says so and without a hint).
 */
public data class ClikgateConsent(
    val analytics: ConsentState,
    val attribution: ConsentState,
    val adUserData: ConsentState,
    val adPersonalization: ConsentState,
    val region: String?,
    val required: Boolean?,
)

/**
 * Options for [Clikgate.enableFirebaseForwarding]. Each switch is combined with
 * the server's `firebase_forwarding` setting of the same name.
 *
 * @property logAttributionEvent Log `clikgate_attribution` once per install.
 * @property setUserProperties Set the `cg_first_source` / `cg_first_campaign` user properties.
 */
public data class FirebaseForwardingOptions @JvmOverloads constructor(
    val logAttributionEvent: Boolean = true,
    val setUserProperties: Boolean = true,
)
