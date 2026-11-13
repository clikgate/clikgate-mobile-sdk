import Foundation

/// Everything in `Application Support/Clikgate/state.json`. A class (owned and mutated only by the
/// core actor) to keep value-witness code small.
final class PersistedState: @unchecked Sendable {
    var installationId: String?
    /// Keychain id found on a fresh install (reinstall); sent with `/install` until it succeeds.
    var keychainPreviousInstallationId: String?
    var installId: String?
    var attribution: ClikgateAttribution?
    var config: RemoteConfig?
    var configFetchedAt: Date?
    var pushToken: String?
    var pushProvider: String?
    var pushApnsEnvironment: String?
    /// sha256(provider + token) of the last token the server acknowledged.
    var lastPushHash: String?
    /// `automaticPushToken` registered on an earlier launch (for the missing-token warning).
    var autoPushRegistered = false
    var customerUserId: String?
    var identityToken: String?
    var identifyPending = false
    /// A label from identifyUser() not sent yet ("" clears it on the server).
    var pendingLabel: String?
    var trackingEnabled = true
    /// The `/opt-out` value still to be sent (nil when in sync with the server).
    var optOutPending: Bool?
    var lastOpenAt: Date?
    var lastBackgroundAt: Date?
    var firstLaunchSignalsCollected = false
    var pasteboardToken: String?
    /// `pasteboard_outcome` for /install (nil when the paste flow didn't run); kept so a retry sends the same value.
    var pasteboardOutcome: String?
    var launchUrl: String?
    var attestKeyId: String?
    var attestKeyAttested = false
    var lastAttestedAt: Date?
    // Consent
    var consent = ConsentPayload()
    /// When buffering for consent started (nil when not buffering).
    var consentPendingSince: Date?
    /// A `/consent` record still to be sent.
    var consentRecordPending = false
    var installPingSent = false
    var firstLaunchAt: Date?
    var odmCollected = false
    var lastAppInstanceIdSent: String?
    var firebaseAttributionLogged = false
    /// Click / link of the latest matched `/resolve` (for `attributionMetadata`).
    var lastClickId: String?
    var lastLinkId: String?
    /// Google click ids of a Clikgate URL handled since the last `/open`.
    var pendingOpenClickIds: GoogleClickIds?
    /// URLs delivered locally while buffering for consent, resolved silently after grant.
    var keptUrls: [String] = []
    /// The launch URL was already delivered locally (consent buffering): don't deliver the
    /// install response's direct deep link for it again.
    var launchUrlDeliveredLocally = false

    var installDone: Bool { installId != nil }

    @inline(never)
    private static func consentState(_ c: JSONObject, _ k: String) -> ClikgateConsentState {
        c.str(k).flatMap(ClikgateConsentState.init(rawValue:)) ?? .unknown
    }

    init() {}

    func copy() -> PersistedState { PersistedState(json: json) }

    @_optimize(size)
    init(json j: JSONObject) {
        installationId = j.str("installation_id")
        keychainPreviousInstallationId = j.str("keychain_previous_installation_id")
        installId = j.str("install_id")
        attribution = j.obj("attribution").map(ClikgateAttribution.init(json:))
        config = j.obj("config").map(RemoteConfig.init(json:))
        configFetchedAt = j.date("config_fetched_at")
        pushToken = j.str("push_token")
        pushProvider = j.str("push_provider")
        pushApnsEnvironment = j.str("push_apns_environment")
        lastPushHash = j.str("last_push_hash")
        autoPushRegistered = j.bool("auto_push_registered") ?? false
        customerUserId = j.str("customer_user_id")
        identityToken = j.str("identity_token")
        identifyPending = j.bool("identify_pending") ?? false
        pendingLabel = j.str("pending_label")
        trackingEnabled = j.bool("tracking_enabled") ?? true
        optOutPending = j.bool("opt_out_pending")
        lastOpenAt = j.date("last_open_at")
        lastBackgroundAt = j.date("last_background_at")
        firstLaunchSignalsCollected = j.bool("first_launch_signals_collected") ?? false
        pasteboardToken = j.str("pasteboard_token")
        pasteboardOutcome = j.str("pasteboard_outcome")
        launchUrl = j.str("launch_url")
        attestKeyId = j.str("attest_key_id")
        attestKeyAttested = j.bool("attest_key_attested") ?? false
        lastAttestedAt = j.date("last_attested_at")
        if let c = j.obj("consent") {
            consent.analytics = Self.consentState(c, "analytics")
            consent.attribution = Self.consentState(c, "attribution")
            consent.adUserData = Self.consentState(c, "ad_user_data")
            consent.adPersonalization = Self.consentState(c, "ad_personalization")
            consent.region = c.str("region")
            consent.updatedAt = c.date("updated_at")
        }
        consentPendingSince = j.date("consent_pending_since")
        consentRecordPending = j.bool("consent_record_pending") ?? false
        installPingSent = j.bool("install_ping_sent") ?? false
        firstLaunchAt = j.date("first_launch_at")
        odmCollected = j.bool("odm_collected") ?? false
        lastAppInstanceIdSent = j.str("last_app_instance_id_sent")
        firebaseAttributionLogged = j.bool("firebase_attribution_logged") ?? false
        lastClickId = j.str("last_click_id")
        lastLinkId = j.str("last_link_id")
        pendingOpenClickIds = GoogleClickIds(json: j.obj("pending_open_click_ids"))
        keptUrls = j.strings("kept_urls")
        launchUrlDeliveredLocally = j.bool("launch_url_delivered_locally") ?? false
    }

    @_optimize(size)
    var json: JSONObject {
        var b = JSONBuilder()
        b.set("version", 1)
        b.set("installation_id", installationId)
        b.set("keychain_previous_installation_id", keychainPreviousInstallationId)
        b.set("install_id", installId)
        b.set("attribution", attribution?.json)
        if let c = config, case .object = c.raw { b.set("config", c.raw.anyValue) }
        b.set("config_fetched_at", configFetchedAt)
        b.set("push_token", pushToken)
        b.set("push_provider", pushProvider)
        b.set("push_apns_environment", pushApnsEnvironment)
        b.set("last_push_hash", lastPushHash)
        b.set("auto_push_registered", autoPushRegistered)
        b.set("customer_user_id", customerUserId)
        b.set("identity_token", identityToken)
        b.set("identify_pending", identifyPending)
        b.set("pending_label", pendingLabel)
        b.set("tracking_enabled", trackingEnabled)
        b.set("opt_out_pending", optOutPending)
        b.set("last_open_at", lastOpenAt)
        b.set("last_background_at", lastBackgroundAt)
        b.set("first_launch_signals_collected", firstLaunchSignalsCollected)
        b.set("pasteboard_token", pasteboardToken)
        b.set("pasteboard_outcome", pasteboardOutcome)
        b.set("launch_url", launchUrl)
        b.set("attest_key_id", attestKeyId)
        b.set("attest_key_attested", attestKeyAttested)
        b.set("last_attested_at", lastAttestedAt)
        var c = JSONBuilder()
        c.set("analytics", consent.analytics.rawValue)
        c.set("attribution", consent.attribution.rawValue)
        c.set("ad_user_data", consent.adUserData.rawValue)
        c.set("ad_personalization", consent.adPersonalization.rawValue)
        c.set("region", consent.region)
        c.set("updated_at", consent.updatedAt)
        b.set("consent", c.object)
        b.set("consent_pending_since", consentPendingSince)
        b.set("consent_record_pending", consentRecordPending)
        b.set("install_ping_sent", installPingSent)
        b.set("first_launch_at", firstLaunchAt)
        b.set("odm_collected", odmCollected)
        b.set("last_app_instance_id_sent", lastAppInstanceIdSent)
        b.set("firebase_attribution_logged", firebaseAttributionLogged)
        b.set("last_click_id", lastClickId)
        b.set("last_link_id", lastLinkId)
        b.set("pending_open_click_ids", pendingOpenClickIds?.json(source: "deep_link"))
        if !keptUrls.isEmpty { b.set("kept_urls", keptUrls) }
        b.set("launch_url_delivered_locally", launchUrlDeliveredLocally)
        return b.object
    }
}

/// A JSON file in the SDK's directory. Not thread-safe on its own; owned by the core actor.
struct JSONFile {
    let url: URL

    init(directory: URL, fileName: String) {
        url = directory.appendingPathComponent(fileName)
    }

    func load() -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    @discardableResult
    func save(_ object: Any) -> Bool {
        guard let data = JSON.data(object) else { return false }
        do {
            try Self.ensureDirectory(url.deletingLastPathComponent())
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    func delete() { try? FileManager.default.removeItem(at: url) }

    static func ensureDirectory(_ dir: URL) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Installation state must not be restored onto another device from a backup
        // (the Keychain copy handles reinstall detection on the same device).
        var d = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? d.setResourceValues(values)
    }
}

/// Persistent event queue (`events.json`), bounded by count and bytes; drops the oldest when full.
final class EventQueue {
    private let file: JSONFile
    private(set) var events: [QueuedEvent]
    private var sizes: [Int]
    var maxEvents: Int
    var maxBytes: Int

    init(directory: URL, maxEvents: Int = 1000, maxBytes: Int = 1_048_576) {
        file = JSONFile(directory: directory, fileName: "events.json")
        events = ((file.load() as? [Any]) ?? []).compactMap { ($0 as? JSONObject).flatMap(QueuedEvent.init(json:)) }
        self.maxEvents = maxEvents
        self.maxBytes = maxBytes
        sizes = events.map { JSON.size($0.json) }
    }

    var count: Int { events.count }
    var totalBytes: Int { sizes.reduce(0, +) }

    func append(_ e: QueuedEvent) {
        events.append(e)
        sizes.append(JSON.size(e.json))
        trim()
        persist()
    }

    func trim() {
        var total = totalBytes
        while !events.isEmpty, events.count > maxEvents || total > maxBytes {
            total -= sizes.removeFirst()
            events.removeFirst()
        }
    }

    func peek(_ n: Int) -> [QueuedEvent] { Array(events.prefix(n)) }

    /// Drops events that occurred before `cutoff` (consent buffer expiry). Returns how many.
    @discardableResult
    func dropOlder(than cutoff: Date) -> Int {
        let old = Set(events.filter { (ISO8601.parse($0.occurredAt) ?? cutoff) < cutoff }.map { $0.eventId })
        remove(ids: old)
        return old.count
    }

    func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var keptE: [QueuedEvent] = []
        var keptS: [Int] = []
        for (e, s) in zip(events, sizes) where !ids.contains(e.eventId) { keptE.append(e); keptS.append(s) }
        events = keptE
        sizes = keptS
        persist()
    }

    func clear() {
        events = []
        sizes = []
        file.delete()
    }

    private func persist() {
        if events.isEmpty { file.delete() } else { file.save(events.map { $0.json }) }
    }
}
