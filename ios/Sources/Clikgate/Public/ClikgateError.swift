import Foundation

/// A failed Clikgate call. `code` is the backend error code (`code_not_found`, `already_referred`, ...)
/// or one of the SDK codes below.
public struct ClikgateError: Error, Sendable, Equatable, LocalizedError, CustomNSError {
    public let code: String
    public let message: String
    /// HTTP status, when the error came from the server.
    public let status: Int?
    /// The request field the error refers to, when the server named one.
    public let param: String?
    public let requestId: String?
    /// For ``featureDisabled``: the switched-off feature key (``ClikgateFeatures``), taken from the
    /// server's answer or, when the SDK skipped the call, the feature of the method.
    public let feature: String?
    /// Engage `codes.redeem` only: the offline touch (`oft_...`) that was recorded although the referral
    /// couldn't be created (`self_referral`, `already_referred`, `window_expired`, ...).
    public let offlineTouchId: String?

    public init(code: String, message: String, status: Int? = nil, param: String? = nil, requestId: String? = nil,
                feature: String? = nil, offlineTouchId: String? = nil) {
        self.code = code
        self.message = message
        self.status = status
        self.param = param
        self.requestId = requestId
        self.feature = feature
        self.offlineTouchId = offlineTouchId
    }

    public var errorDescription: String? { "\(code): \(message)" }

    public static var errorDomain: String { "com.clikgate.sdk" }
    public var errorCode: Int { status ?? -1 }
    public var errorUserInfo: [String: Any] {
        var info: [String: Any] = [NSLocalizedDescriptionKey: message, "code": code]
        if let param = param { info["param"] = param }
        if let requestId = requestId { info["request_id"] = requestId }
        if let feature = feature { info["feature"] = feature }
        if let offlineTouchId = offlineTouchId { info["offline_touch_id"] = offlineTouchId }
        return info
    }

    // SDK codes
    public static let notConfigured = "not_configured"
    public static let networkError = "network_error"
    public static let optedOut = "opted_out"
    public static let invalidArgument = "invalid_argument"
    public static let timeout = "timeout"
    public static let installPending = "install_pending"
    /// The feature behind the call is switched off for this app: either the cached config says so
    /// (no network call was made) or the server answered with its `feature_disabled` no-op body.
    /// ``feature`` names it.
    public static let featureDisabled = "feature_disabled"
    /// Consent is required for this device and `attribution` isn't granted, so the call
    /// wasn't sent (it would identify the installation).
    public static let consentRequired = "consent_required"
    /// This SDK version is blocked by Clikgate and the call isn't among the allowed ones.
    public static let sdkVersionBlocked = "sdk_version_blocked"

    // Backend codes
    public static let invalidSdkKey = "invalid_sdk_key"
    public static let sdkDisabled = "sdk_disabled"
    public static let installationUnknown = "installation_unknown"
    public static let installInProgress = "install_in_progress"
    public static let validationError = "validation_error"
    public static let rateLimited = "rate_limited"
    public static let serverError = "server_error"
    public static let notIdentified = "not_identified"
    public static let identityRequired = "identity_required"
    public static let identityInvalid = "identity_invalid"
    public static let programNotFound = "program_not_found"
    public static let programPaused = "program_paused"
    public static let manualEntryDisabled = "manual_entry_disabled"
    public static let codeNotFound = "code_not_found"
    public static let alreadyReferred = "already_referred"
    public static let windowExpired = "window_expired"
    public static let selfReferral = "self_referral"
    public static let referrerBlocked = "referrer_blocked"
    // Link creation, stats, leaderboard and promo-code codes are declared by the Engage features.

    static func featureDisabledError(_ feature: String) -> ClikgateError {
        ClikgateError(code: featureDisabled, message: "The '\(feature)' feature is switched off for this app.", feature: feature)
    }

    static func notConfiguredError() -> ClikgateError {
        ClikgateError(code: notConfigured, message: "Call Clikgate.configure(sdkKey:options:) first.")
    }
}
