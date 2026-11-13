import Foundation

// Request/response bodies of the Clikgate SDK API. snake_case on the wire.

struct RemoteConfig: Sendable {
    struct Features: Sendable {
        var deferredDeepLinking = false
        var pasteboardMatching = "off"
        var appleSearchAds = false
        var uninstallTracking = false
        var restrictedMode = false
        var iosAppAttest = "off"
        var identityChecks = false
    }

    /// `consent`: nil when the server sent none (older servers).
    struct Consent: Sendable {
        var mode = "not_required"
        var required = false
        var requiredRegions = ConsentRegions.defaultRequired
        var anonymousCounts = false
        var bufferMaxDays = 7
        var bufferMaxEvents = 1000
        var identityChecksBasis = "consent"
    }

    /// `blocked_instructions`.
    struct Blocked: Sendable {
        var allowedCalls = SDKCall.blockedDefault
        var message: String?
    }

    /// `firebase_forwarding`; nil = off.
    struct Firebase: Sendable {
        var enabled = false
        var logAttributionEvent = true
        var setUserProperties = true
        var reportAppInstanceId = true
    }

    /// `private_mode`; absent = off. `allow_labels`; absent = on.
    var privateMode = false
    var allowLabels = true

    struct Batching: Sendable {
        var maxBatchSize = 100
        var flushIntervalSeconds = 15
        var flushAtCount = 20
        var maxQueueEvents = 1000
        var maxQueueBytes = 1_048_576
    }

    var appId: String?
    var environment: String?
    var linkDomains: [String] = []
    var features = Features()
    var batching = Batching()
    var reattestationIntervalDays = 7
    var sessionTimeoutMinutes = 30
    var consent: Consent?
    var minSupportedVersion: String?
    var latestVersion: String?
    var versionStatus: String?
    var blocked: Blocked?
    var firebase: Firebase?
    /// v3 feature switches: the boolean entries of `features` (already resolved for this app).
    /// nil when the response had no `features` object (and for the built-in defaults).
    var switches: [String: Bool]?
    /// The response as received (persisted in state.json and re-parsed on launch).
    var raw: JSONValue = .null

    /// Defaults when no config is available: everything off.
    init() {}

    @_optimize(size)
    init(json j: JSONObject) {
        raw = JSONValue(any: j) ?? .null
        appId = j.str("app_id")
        environment = j.str("environment")
        // Optional (pre-Part-3 servers omit it); not an array → [], non-string / empty items dropped.
        linkDomains = j.strings("link_domains").map(LinkMatcher.normalize).filter { !$0.isEmpty }
        if let f = j.obj("features") {
            features.deferredDeepLinking = f.bool("deferred_deep_linking") ?? false
            features.pasteboardMatching = f.str("pasteboard_matching") ?? "off"
            features.appleSearchAds = f.bool("apple_search_ads") ?? false
            features.uninstallTracking = f.bool("uninstall_tracking") ?? false
            features.restrictedMode = f.bool("restricted_mode") ?? false
            features.iosAppAttest = f.obj("attestation")?.str("ios_app_attest") ?? "off"
            features.identityChecks = f.bool("identity_checks") ?? false
            var sw: [String: Bool] = [:]
            for (k, v) in f {
                // Only JSON booleans are switches (`pasteboard_matching`, `attestation` aren't).
                if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { sw[k] = n.boolValue }
            }
            switches = sw
        }
        if let b = j.obj("batching") {
            batching.maxBatchSize = Swift.min(100, Swift.max(1, b.int("max_batch_size") ?? 100))
            batching.flushIntervalSeconds = Swift.max(1, b.int("flush_interval_seconds") ?? 15)
            batching.flushAtCount = Swift.max(1, b.int("flush_at_count") ?? 20)
            batching.maxQueueEvents = Swift.max(1, b.int("max_queue_events") ?? 1000)
            batching.maxQueueBytes = Swift.max(1024, b.int("max_queue_bytes") ?? 1_048_576)
        }
        reattestationIntervalDays = Swift.max(1, j.int("reattestation_interval_days") ?? 7)
        sessionTimeoutMinutes = Swift.max(1, j.int("session_timeout_minutes") ?? 30)
        if let c = j.obj("consent") {
            var x = Consent()
            x.mode = c.str("mode") ?? "not_required"
            x.required = c.bool("required") ?? false
            if c["required_regions"] is [Any] { x.requiredRegions = c.strings("required_regions") }
            x.anonymousCounts = c.bool("anonymous_counts") ?? false
            x.bufferMaxDays = Swift.min(7, Swift.max(1, c.int("buffer_max_days") ?? 7))
            x.bufferMaxEvents = Swift.min(1000, Swift.max(1, c.int("buffer_max_events") ?? 1000))
            x.identityChecksBasis = c.str("identity_checks_basis") ?? "consent"
            consent = x
        }
        minSupportedVersion = j.str("min_supported_version")
        latestVersion = j.str("latest_version")
        versionStatus = j.str("version_status")
        if versionStatus == "blocked" {
            var b = Blocked()
            if let o = j.obj("blocked_instructions") {
                if o["allowed_calls"] is [Any] { b.allowedCalls = o.strings("allowed_calls") }
                b.message = o.str("message")
            }
            blocked = b
        }
        privateMode = j.bool("private_mode") ?? false
        allowLabels = j.bool("allow_labels") ?? true
        if let f = j.obj("firebase_forwarding") {
            firebase = Firebase(enabled: f.bool("enabled") ?? false,
                                logAttributionEvent: f.bool("log_attribution_event") ?? true,
                                setUserProperties: f.bool("set_user_properties") ?? true,
                                reportAppInstanceId: f.bool("report_app_instance_id") ?? true)
        }
    }
}

struct PushPayload: Sendable {
    var provider: String
    var token: String
    var apnsEnvironment: String?

    var json: JSONObject {
        ["provider": provider, "token": token, "apns_environment": apnsEnvironment ?? NSNull()]
    }
}

struct AttestationPayload: Sendable {
    var type: String
    var token: String
    var keyId: String?
    var challenge: String

    var json: JSONObject {
        ["type": type, "token": token, "key_id": keyId ?? NSNull(), "challenge": challenge]
    }
}

/// The request-side `consent` object.
struct ConsentPayload: Sendable {
    var analytics: ClikgateConsentState = .unknown
    var attribution: ClikgateConsentState = .unknown
    var adUserData: ClikgateConsentState = .unknown
    var adPersonalization: ClikgateConsentState = .unknown
    var region: String?
    var updatedAt: Date?

    /// The opted-out first `/install` says so with every purpose denied
    /// (`attribution: denied` replaces the old `tracking_allowed: false`, which the SDK no longer sends).
    var optedOut: ConsentPayload {
        var c = self
        c.analytics = .denied; c.attribution = .denied; c.adUserData = .denied; c.adPersonalization = .denied
        return c
    }

    var isAllDenied: Bool {
        analytics == .denied && attribution == .denied && adUserData == .denied && adPersonalization == .denied
    }

    func json() -> JSONObject {
        var b = JSONBuilder()
        b.set("analytics", analytics.rawValue)
        b.set("attribution", attribution.rawValue)
        b.set("ad_user_data", adUserData.rawValue)
        b.set("ad_personalization", adPersonalization.rawValue)
        b.setOrNull("region", region)
        b.setOrNull("updated_at", updatedAt.map(ISO8601.format))
        return b.object
    }
}

struct InstallRequest: Sendable {
    var installationId: String
    var keychainPreviousInstallationId: String?
    var appVersion: String
    var sdkVersion: String
    var osVersion: String?
    var deviceModel: String?
    var locale: String?
    var timezone: String?
    var launchUrl: String?
    var pasteboardToken: String?
    var pasteboardOutcome: String?
    var push: PushPayload?
    var attestation: AttestationPayload?
    var appleSearchAdsToken: String?
    var trackingAllowed: Bool
    var isEmulator: Bool?
    var consent = ConsentPayload()
    var googleClickIds: GoogleClickIds?
    var appInstanceId: String?
    var deviceCheckToken: String?
    var idfv: String?
    var odmInfo: String?
    var odmSdkVersion: String?

    /// Optional fields are omitted when nil, which the schema allows.
    @_optimize(size)
    var json: JSONObject {
        var b = JSONBuilder()
        b.set("installation_id", installationId)
        b.set("keychain_previous_installation_id", keychainPreviousInstallationId)
        b.set("app_version", appVersion)
        b.set("sdk_version", sdkVersion)
        b.set("platform", "ios")
        b.set("os_version", osVersion)
        b.set("device_model", deviceModel)
        b.set("locale", locale)
        b.set("timezone", timezone)
        b.set("launch_url", launchUrl)
        b.set("pasteboard_token", pasteboardToken)
        b.set("pasteboard_outcome", pasteboardOutcome)
        b.set("push", push?.json)
        b.set("attestation", attestation?.json)
        b.set("apple_search_ads_token", appleSearchAdsToken)
        b.set("consent", trackingAllowed ? consent.json() : consent.optedOut.json())
        b.set("is_emulator", isEmulator)
        b.set("google_click_ids", googleClickIds?.json(source: "deep_link"))
        b.set("app_instance_id", appInstanceId)
        b.set("device_check_token", deviceCheckToken)
        b.set("idfv", idfv)
        if let odm = odmInfo {
            b.set("google_on_device_measurement", ["odm_info": odm, "sdk_version": odmSdkVersion ?? NSNull()] as JSONObject)
        }
        return b.object
    }
}

struct WireDeepLink: Sendable {
    var url: String?
    var path: String?
    var data: [String: JSONValue]
    var isDeferred: Bool?

    init?(json j: JSONObject?) {
        guard let j = j else { return nil }
        url = j.str("url"); path = j.str("path")
        data = JSONValue.object(from: j["data"])
        isDeferred = j.bool("is_deferred")
    }
}

struct InstallResponse: Sendable {
    var installId: String
    var attribution: ClikgateAttribution?
    var deepLink: WireDeepLink?
    var referral: ClikgateReferral?
    var retryAfterMs: Int?
    /// The dashboard's debug view is open for this app (report the handled deep link).
    var debugView = false
    /// The launch URL matched, so /install already recorded its click.
    var launchMatched = false

    @_optimize(size)
    init?(json j: JSONObject?) {
        guard let j = j, let id = j.str("install_id") else { return nil }
        debugView = j.bool("debug_view") ?? false
        installId = id
        attribution = j.obj("attribution").map(ClikgateAttribution.init(json:))
        // A gated launch URL never routes into the app; with no deep link the launch URL is
        // /resolve'd as before, which gives the gate's answer (password page / blocked).
        let status = j.str("status")
        launchMatched = status == "matched"
        deepLink = status == "password_required" || status == "blocked" ? nil : WireDeepLink(json: j.obj("deep_link"))
        referral = ClikgateReferral(json: j.obj("referral"))
        retryAfterMs = j.int("retry_after_ms")
    }
}

struct ResolveResponse: Sendable {
    var matched: Bool
    var clickId: String?
    var deepLink: WireDeepLink?
    var link: ClikgateLink?
    var referral: ClikgateReferral?
    /// Gates (`status`): `password_required` → the URL to open in the browser; `blocked` → the text.
    var webUrl: String?
    var blockMessage: String?
    var debugView = false
    /// The click of an App banner tap measuring the right screen (`measure_right_screen`).
    var bannerClickId: String?

    @_optimize(size)
    init?(json j: JSONObject?) {
        guard let j = j else { return nil }
        debugView = j.bool("debug_view") ?? false
        if j.bool("measure_right_screen") == true { bannerClickId = j.str("click_id") }
        switch j.str("status") {
        case "password_required": webUrl = j.str("web_url") ?? ""
        case "blocked": blockMessage = j.str("block_message") ?? ""
        default:
            // A gated answer never routes into the app, whatever else it carries.
            matched = j.bool("matched") ?? false
            clickId = j.str("click_id")
            deepLink = WireDeepLink(json: j.obj("deep_link"))
            link = ClikgateLink(json: j.obj("link"))
            referral = ClikgateReferral(json: j.obj("referral"))
            return
        }
        matched = false
    }
}

struct QueuedEvent: Sendable {
    /// The `/goals` item (`name` = key, `eventId` = dedupe key). Nil only for an app event an earlier development
    /// build left in the persisted queue (dropped on the next flush, never sent).
    var goal: [String: JSONValue]?
    var eventId: String
    var name: String
    var occurredAt: String
    /// The `goal()` completion (in memory only).
    var done: (@Sendable (ClikgateGoalResult) -> Void)?

    init(eventId: String, name: String, occurredAt: String) {
        self.eventId = eventId; self.name = name; self.occurredAt = occurredAt
    }

    init?(json j: JSONObject) {
        guard let id = j.str("event_id"), let name = j.str("name"), let at = j.str("occurred_at") else { return nil }
        eventId = id; self.name = name; occurredAt = at
        goal = j.obj("goal").map { JSONValue.object(from: $0) }
    }

    /// The persisted form (the queue file).
    var json: JSONObject {
        var b = JSONBuilder()
        b.set("event_id", eventId); b.set("name", name); b.set("occurred_at", occurredAt)
        b.set("goal", goal?.anyDictionary)
        return b.object
    }
}

struct AttestChallengeResponse: Sendable {
    var challenge: String
    var nonce: String

    init?(json j: JSONObject?) {
        guard let j = j, let c = j.str("challenge"), let n = j.str("nonce") else { return nil }
        challenge = c; nonce = n
    }
}
