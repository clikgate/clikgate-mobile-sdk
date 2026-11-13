package com.clikgate

/** SDK log level. Logs never contain the SDK key, push tokens or identity tokens. */
public enum class LogLevel { VERBOSE, DEBUG, INFO, WARN, ERROR, NONE }

/** The app environment the SDK key belongs to (informational; the key decides server-side). */
public enum class Environment { PRODUCTION, SANDBOX }

/** Device attestation on install. */
public enum class Attestation {
    OFF,

    /**
     * Use Play Integrity when the app depends on `com.google.android.play:integrity`, the device
     * runs Android 6.0+, and the app's Clikgate settings enable Play Integrity.
     */
    PLAY_INTEGRITY_IF_AVAILABLE,
}

/**
 * Options for [Clikgate.configure].
 *
 * @property linkDomains Your Clikgate link domains (e.g. `inv.myapp.com`): list **every** domain of
 *   your domain group (aliases such as `acme.ng` and `go.acme.com` are the same links), each with
 *   an `autoVerify` intent filter. Merged with the server config's `link_domains` (case-insensitive);
 *   the domains listed here always count, including on the very first launch before the config has
 *   been fetched. The SDK logs a warning for a server domain missing here.
 * @property apiBaseUrl Clikgate SDK API base URL; keep the default.
 * @property deferredDeepLinkTimeoutMs How long [Clikgate.attribution] / [Clikgate.awaitAttribution]
 *   wait for the first-launch attribution before resolving with status `pending`. The deferred
 *   deep link itself is delivered whenever it arrives.
 * @property cloudProjectNumber Google Cloud project number for Play Integrity (needed only for
 *   apps distributed outside Google Play).
 * @property platformDomainBrowserFallback When a link on a shared Clikgate domain (`ciz.to`, `clk.ng`,
 *   `clkg.to`, `dev.ciz.to`) opens the app but belongs to another organisation (`/resolve` answers
 *   `matched: false`), open it in an in-app browser (Custom Tabs) and report it to
 *   [Clikgate.onBrowserHandoff]. Default true; false = the link is dropped (pre-1.4.0 behaviour).
 * @property automaticPushToken When the app ships Firebase Cloud Messaging, fetch its token on each
 *   launch (by reflection; no Firebase dependency) and use it for uninstall checks, as if passed to
 *   [Clikgate.setPushToken]. Only when uninstall tracking is on for the app, tracking isn't opted
 *   out, the SDK version isn't blocked and consent allows it. Never asks for notification
 *   permission. A token passed to [Clikgate.setPushToken] in the same launch always wins.
 *   Default true; false = only [Clikgate.setPushToken] tokens are used.
 */
public data class ClikgateOptions @JvmOverloads constructor(
    val linkDomains: List<String> = emptyList(),
    val logLevel: LogLevel = LogLevel.WARN,
    val environment: Environment = Environment.PRODUCTION,
    val attestation: Attestation = Attestation.OFF,
    val apiBaseUrl: String = DEFAULT_API_BASE_URL,
    val deferredDeepLinkTimeoutMs: Long = 5_000,
    val cloudProjectNumber: Long? = null,
    val platformDomainBrowserFallback: Boolean = true,
    val automaticPushToken: Boolean = true,
) {
    public companion object {
        public const val DEFAULT_API_BASE_URL: String = "https://sdk.clikgate.com"
    }
}
