import Foundation

/// A consent purpose's state.
public enum ClikgateConsentState: String, Sendable {
    case granted, denied, unknown
}

/// The consent the app set with ``Clikgate/setConsent(analytics:attribution:adUserData:adPersonalization:)``.
public struct ClikgateConsent: Sendable, Equatable {
    /// Measure usage (also the basis for Firebase forwarding and, by default, identity checks).
    public var analytics: ClikgateConsentState
    /// Link installs and conversions to their sources. While consent is required and this is
    /// `unknown`, the SDK buffers on the device and sends nothing identifying.
    public var attribution: ClikgateConsentState
    /// Send user data to ad platforms.
    public var adUserData: ClikgateConsentState
    /// Let ad platforms use it for personalised ads.
    public var adPersonalization: ClikgateConsentState
    /// The region hint from ``Clikgate/setConsentRegion(_:)`` (`EEA`, `UK` or a country code).
    public var region: String?
    /// Whether consent is required for this device; nil until the SDK knows (no config with a
    /// consent mode yet and no region hint).
    public var isRequired: Bool?

    public init(analytics: ClikgateConsentState = .unknown, attribution: ClikgateConsentState = .unknown,
                adUserData: ClikgateConsentState = .unknown, adPersonalization: ClikgateConsentState = .unknown,
                region: String? = nil, isRequired: Bool? = nil) {
        self.analytics = analytics
        self.attribution = attribution
        self.adUserData = adUserData
        self.adPersonalization = adPersonalization
        self.region = region
        self.isRequired = isRequired
    }
}

/// Options for ``Clikgate/enableFirebaseForwarding(_:)``. Each one is ANDed with
/// the server switch of the same name in `/v1/sdk/config` `firebase_forwarding`.
public struct ClikgateFirebaseForwardingOptions: Sendable {
    /// Log `clikgate_attribution` once per installation.
    public var logAttributionEvent: Bool
    /// Set the user properties `cg_first_source` and `cg_first_campaign`.
    public var setUserProperties: Bool
    /// Also log every `track()` event to Firebase.
    public var mirrorEvents: Bool
    /// Clikgate event name → Firebase event name for mirrored events.
    public var eventNameMap: [String: String]

    public init(logAttributionEvent: Bool = true, setUserProperties: Bool = true, mirrorEvents: Bool = false,
                eventNameMap: [String: String] = [:]) {
        self.logAttributionEvent = logAttributionEvent
        self.setUserProperties = setUserProperties
        self.mirrorEvents = mirrorEvents
        self.eventNameMap = eventNameMap
    }
}
