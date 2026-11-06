import Foundation

/// SDK configuration passed to `Clikgate.configure(sdkKey:options:)`.
public struct ClikgateOptions: Sendable {
    public enum LogLevel: Int, Sendable, Comparable {
        case verbose = 0, debug, info, warning, error, none
        public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Environment: String, Sendable {
        case production, sandbox
    }

    /// Clipboard deferred deep link (opt-in since 1.2.0; default `.off`).
    public enum PasteboardMode: String, Sendable {
        /// Never touch the pasteboard (default).
        case off
        /// On the first launch only, and only when the server enables pasteboard matching:
        /// check `detectPatterns` (no prompt) and read the pasteboard if a web URL is likely
        /// (iOS 16+ shows the system paste prompt).
        case automatic
        /// Never read automatically; the app shows `ClikgatePasteControl`.
        case pasteControlOnly
    }

    public enum Attestation: String, Sendable {
        case off
        /// Use App Attest when the device supports it and the server enables it.
        case appAttestIfAvailable
    }

    /// Base URL of the Clikgate SDK API. Override only for local testing.
    public var apiBaseUrl: URL
    /// Your Clikgate link domains: list **every** domain of your domain group (aliases such as
    /// `ybr.ng` and `go.yourbrand.com` are the same links) and add each one to the Associated Domains
    /// entitlement as `applinks:<domain>`. Merged with the server config's `link_domains`
    /// (case-insensitive); these always count, also before the first config fetch. The SDK logs a
    /// warning for a server domain missing here.
    public var linkDomains: [String]
    public var logLevel: LogLevel
    /// The environment this build expects; a mismatch with the SDK key's app is logged.
    public var environment: Environment
    public var pasteboardMode: PasteboardMode
    /// Delay the first `/install` call (up to 30 s) until the app has resolved the ATT prompt.
    /// The SDK never shows the ATT prompt itself.
    public var waitForATT: Bool
    public var attestation: Attestation
    /// How long `attribution()` waits for the first `/install` before resolving with `pending`.
    public var deferredDeepLinkTimeout: TimeInterval
    /// A link on a shared Clikgate domain (`ciz.to`, `clk.ng`, `clkg.to`, `dev.ciz.to`) that isn't this
    /// app's (`/resolve` says `matched: false`) opens in an in-app browser (SFSafariViewController)
    /// and is reported as `Clikgate.browserHandoffNotification`. Default true; false drops it (pre-1.4.0 behaviour).
    public var platformDomainBrowserFallback: Bool

    public static let defaultApiBaseUrl = URL(string: "https://sdk.clikgate.com")!

    public init(
        apiBaseUrl: URL = ClikgateOptions.defaultApiBaseUrl,
        linkDomains: [String] = [],
        logLevel: LogLevel = .warning,
        environment: Environment = .production,
        pasteboardMode: PasteboardMode = .off,
        waitForATT: Bool = false,
        attestation: Attestation = .off,
        deferredDeepLinkTimeout: TimeInterval = 5,
        platformDomainBrowserFallback: Bool = true
    ) {
        self.platformDomainBrowserFallback = platformDomainBrowserFallback
        self.apiBaseUrl = apiBaseUrl
        self.linkDomains = linkDomains
        self.logLevel = logLevel
        self.environment = environment
        self.pasteboardMode = pasteboardMode
        self.waitForATT = waitForATT
        self.attestation = attestation
        self.deferredDeepLinkTimeout = deferredDeepLinkTimeout
    }
}
