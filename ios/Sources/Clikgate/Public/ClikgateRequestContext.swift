import Foundation

/// **Internal.** The request context the optional Engage add-on (`ClikgateEngage`) uses to call
/// `/v1/sdk/*` on behalf of this installation. Not part of the app-facing API: it is
/// `@_spi(ClikgateEngage)` and may change without notice.
///
/// Engage keeps no attribution state of its own; everything installation-specific comes from here.
@_spi(ClikgateEngage)
public struct ClikgateRequestContext: Sendable, Equatable {
    /// `Clikgate-Installation-Id` (UUIDv4, lowercase).
    public let installationId: String
    /// `Clikgate-SDK-Key`.
    public let sdkKey: String
    /// `production` or `sandbox` (the server-reported environment of the key's app when known,
    /// else `ClikgateOptions.environment`).
    public let environment: String
    /// The SDK API base URL (`ClikgateOptions.apiBaseUrl`).
    public let apiBaseUrl: URL
    /// The identity token from the last `identify`, sent as `Clikgate-Identity-Token`.
    public let identityToken: String?
    /// The identified user, nil when the installation isn't identified.
    public let customerUserId: String?
    /// Exact `Clikgate-SDK-Version` header value (`ios/1.0.0`, or the wrapper's `flutter/1.0.0`, ...).
    public let sdkVersion: String
    /// `Clikgate-SDK-Native-Version` header value when wrapped (`ios/1.0.0`), else nil.
    public let nativeSdkVersion: String?

    public init(installationId: String, sdkKey: String, environment: String, apiBaseUrl: URL,
                identityToken: String?, customerUserId: String?, sdkVersion: String, nativeSdkVersion: String?) {
        self.installationId = installationId
        self.sdkKey = sdkKey
        self.environment = environment
        self.apiBaseUrl = apiBaseUrl
        self.identityToken = identityToken
        self.customerUserId = customerUserId
        self.sdkVersion = sdkVersion
        self.nativeSdkVersion = nativeSdkVersion
    }

    /// The headers every `/v1/sdk` call carries (without `Accept` / `Content-Type`).
    public var headers: [String: String] {
        var h = ["Clikgate-SDK-Key": sdkKey, "Clikgate-SDK-Version": sdkVersion, "Clikgate-Installation-Id": installationId]
        if let n = nativeSdkVersion { h["Clikgate-SDK-Native-Version"] = n }
        if let t = identityToken { h["Clikgate-Identity-Token"] = t }
        return h
    }
}
