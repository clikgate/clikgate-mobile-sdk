import Foundation

/// An amount of money in minor units (e.g. kobo, cents) with an ISO 4217 currency code, for `track` revenue.
/// Create it with `ClikgateMoney.ofMinor(1_500_000, currency: "NGN")` (₦15,000). Goals take normal units instead.
public struct ClikgateMoney: Sendable, Equatable {
    public let amountMinor: Int64
    public let currency: String

    /// `amountMinor` in minor units (kobo, cents): `ofMinor(1_500_000, currency: "NGN")` is ₦15,000.
    public static func ofMinor(_ amountMinor: Int64, currency: String) -> ClikgateMoney {
        ClikgateMoney(minor: amountMinor, currency: currency)
    }

    private init(minor: Int64, currency: String) {
        self.amountMinor = minor
        self.currency = currency
    }
}

/// The Clikgate link behind a deep link or an attribution.
public struct ClikgateLink: Sendable {
    public let id: String
    /// `standard` or `referral`.
    public let kind: String
    public let externalReference: String?
    public let campaignId: String?
    let metadataJSON: [String: JSONValue]

    public var metadata: [String: Any] { metadataJSON.anyDictionary }

    init?(json: JSONObject?) {
        guard let j = json, let id = j.str("id") else { return nil }
        self.id = id
        kind = j.str("kind") ?? "standard"
        externalReference = j.str("external_reference")
        campaignId = j.str("campaign_id")
        metadataJSON = JSONValue.object(from: j["metadata"])
    }

    var json: JSONObject {
        var b = JSONBuilder()
        b.set("id", id); b.set("kind", kind)
        b.setOrNull("external_reference", externalReference); b.setOrNull("campaign_id", campaignId)
        b.set("metadata", metadataJSON.anyDictionary)
        return b.object
    }
}

/// A referral (one referee attributed to one referrer).
public struct ClikgateReferral: Sendable, Equatable {
    public let referralId: String
    public let programId: String
    /// `installed` | `signed_up` | `in_progress` | `holding` | `qualified` | `disqualified` | `rejected`.
    public let status: String
    /// `link` | `code_entry` | `byo_code`.
    public let source: String?
    public let referrerId: String
    public let referrerDisplayName: String?
    let createdAtString: String?

    public var createdAt: Date? { ISO8601.parse(createdAtString) }
    /// The server's timestamp string (wrappers pass it through unchanged).
    @_spi(ClikgateWrapper) public var createdAtRaw: String? { createdAtString }

    /// Decodes an API referral object (used by the Engage add-on).
    @_spi(ClikgateEngage) public init?(apiJSON: [String: Any]?) { self.init(json: apiJSON) }

    init?(json: JSONObject?) {
        guard let j = json, let rid = j.str("referral_id") else { return nil }
        referralId = rid
        programId = j.str("program_id") ?? ""
        status = j.str("status") ?? "installed"
        source = j.str("source")
        referrerId = j.str("referrer_id") ?? ""
        referrerDisplayName = j.str("referrer_display_name")
        createdAtString = j.str("created_at")
    }
}

/// A deep link delivered to `onDeepLink` — deferred (first launch) or direct (Universal Link / scheme).
public struct ClikgateDeepLinkResult: Sendable {
    public let url: URL?
    public let path: String?
    let dataJSON: [String: JSONValue]
    public let isDeferred: Bool
    public let clickId: String?
    public let matchType: String?
    public let link: ClikgateLink?
    public let referral: ClikgateReferral?
    /// Change 17: set when the link is blocked here (allowed countries or a block rule): show this text and don't
    /// route; `path`, `clickId` and `link` are nil.
    public internal(set) var blockMessage: String? = nil

    public var data: [String: Any] { dataJSON.anyDictionary }
}

/// Install attribution for this installation.
public struct ClikgateAttribution: Sendable {
    public enum Status: String, Sendable {
        case pending, attributed, organic
    }

    public let status: Status
    /// `app_link` | `install_referrer` | `pasteboard` | `probabilistic` | `apple_search_ads` | `code_entry`, or nil (organic).
    public let matchType: String?
    public let confidence: Double?
    public let clickId: String?
    let clickedAtString: String?
    public let isReinstall: Bool
    public internal(set) var installId: String?
    public let link: ClikgateLink?
    /// Optional server fields: attribution source, medium, campaign name and channel
    /// (`ads`, `whatsapp`, `referral`, `offline_code`, `link`, `organic`); nil from older servers.
    public let source: String?
    public let medium: String?
    public let campaign: String?
    public let channel: String?

    public var clickedAt: Date? { ISO8601.parse(clickedAtString) }
    /// The server's timestamp string (wrappers pass it through unchanged).
    @_spi(ClikgateWrapper) public var clickedAtRaw: String? { clickedAtString }

    @_optimize(size)
    init(json j: JSONObject) {
        status = j.str("status").flatMap(Status.init(rawValue:)) ?? .pending
        matchType = j.str("match_type")
        confidence = j.double("confidence")
        clickId = j.str("click_id")
        clickedAtString = j.str("clicked_at")
        isReinstall = j.bool("is_reinstall") ?? false
        installId = j.str("install_id")
        link = ClikgateLink(json: j.obj("link"))
        source = j.str("source"); medium = j.str("medium"); campaign = j.str("campaign"); channel = j.str("channel")
    }

    var json: JSONObject {
        var b = JSONBuilder()
        b.set("source", source); b.set("medium", medium); b.set("campaign", campaign); b.set("channel", channel)
        b.set("status", status.rawValue)
        b.setOrNull("match_type", matchType); b.setOrNull("confidence", confidence)
        b.setOrNull("click_id", clickId); b.setOrNull("clicked_at", clickedAtString)
        b.set("is_reinstall", isReinstall); b.setOrNull("install_id", installId)
        b.setOrNull("link", link?.json)
        return b.object
    }

    init(status: Status, installId: String? = nil) {
        self.status = status
        matchType = nil; confidence = nil; clickId = nil; clickedAtString = nil
        isReinstall = false; link = nil
        source = nil; medium = nil; campaign = nil; channel = nil
        self.installId = installId
    }
}

/// Whether this installation was referred, and by whom.
public struct ClikgateReferredBy: Sendable, Equatable {
    public let referred: Bool
    public let referral: ClikgateReferral?

    init?(json j: JSONObject?) {
        guard let j = j, let referred = j.bool("referred") else { return nil }
        self.referred = referred
        referral = ClikgateReferral(json: j.obj("referral"))
    }
}

// MARK: - v3: feature switches

/// Feature keys for ``Clikgate/isFeatureEnabled(_:)`` (the SDK-relevant organisation features
/// that `/v1/sdk/config` reports).
public enum ClikgateFeatures {
    public static let appAttribution = "app_attribution"
    /// `referrals.applyCode` / `referrals.referredBy` (and the Engage add-on's referral calls).
    public static let referrals = "referrals"
    /// Used by the Engage add-on (`ClikgateEngage.leaderboards`).
    public static let leaderboards = "leaderboards"
    public static let identityChecks = "identity_checks"
    public static let whatsappAttribution = "whatsapp_attribution"
    /// Used by the Engage add-on (`ClikgateEngage.codes`).
    public static let offlineCodes = "offline_codes"
    public static let skanPostbacks = "skan_postbacks"
    public static let uninstallTracking = "uninstall_tracking"
    public static let probabilisticMatching = "probabilistic_matching"
    public static let appleSearchAds = "apple_search_ads"
}

/// The outcome of a goal (`"\(status)"` is its wire value: `counted`, `waiting`, `refused`).
public enum ClikgateGoalStatus: Sendable {
    /// The goal counted.
    case counted
    /// Recorded, not counted yet: a Payment goal waiting for its confirmation, or a goal waiting for its click.
    case waiting
    /// Not counted; `reason` says why.
    case refused
}

/// A goal's kind, set in the dashboard: Standard goals count when they're sent, Payment goals when your payment
/// provider or server confirms them.
public enum ClikgateGoalKind: Sendable {
    case standard, payment
}

/// The result of `goal(...)`.
public struct ClikgateGoalResult: Sendable {
    public let status: ClikgateGoalStatus
    /// Nil when counted; else a reason code such as `waiting_for_confirmation`, `unattributed`,
    /// `payment_goal_needs_confirmation` or `invalid_argument`.
    public let reason: String?
    /// The goal's kind; nil when the goal didn't reach Clikgate.
    public let goalKind: ClikgateGoalKind?
    /// True when a value was sent for a Payment goal and ignored (the amount comes from the confirmation).
    public let valueIgnored: Bool

    static func refused(_ reason: String) -> ClikgateGoalResult {
        ClikgateGoalResult(status: .refused, reason: reason, goalKind: nil, valueIgnored: false)
    }
}
