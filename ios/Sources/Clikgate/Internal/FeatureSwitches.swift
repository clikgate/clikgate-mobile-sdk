import Foundation

/// v3 feature switches, readable from any thread so
/// `Clikgate.isFeatureEnabled(_:)` stays synchronous while the core is an actor.
///
/// Value of a key: the server's boolean when the config lists it, else the catalogue default
/// (`defaultOn`); unknown keys are off. Features the server answered `feature_disabled` for read
/// as off until the next successful `/config` fetch.
final class FeatureSwitches: @unchecked Sendable {
    /// Features that count as on when no config is known yet or an (older) server doesn't list them.
    static let defaultOn: Set<String> = ["referrals", "leaderboards", "offline_codes", "app_attribution", "deep_linking"]

    private let lock = NSLock()
    private var switches: [String: Bool]?
    private var disabledByServer: Set<String> = []

    init(switches: [String: Bool]? = nil) {
        self.switches = switches
    }

    static func isEnabled(_ key: String, switches: [String: Bool]?) -> Bool {
        switches?[key] ?? defaultOn.contains(key)
    }

    func isEnabled(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if disabledByServer.contains(key) { return false }
        return Self.isEnabled(key, switches: switches)
    }

    /// A freshly fetched (or the cached) config. A fetched config is authoritative again, so the
    /// server-reported switch-offs are cleared (a re-enabled feature works without a relaunch).
    func apply(_ switches: [String: Bool]?, clearServerDisabled: Bool) {
        lock.lock()
        self.switches = switches
        if clearServerDisabled { disabledByServer.removeAll() }
        lock.unlock()
    }

    /// The server answered `{"accepted": false, "reason": "feature_disabled"}`.
    func markDisabled(_ keys: String...) {
        lock.lock()
        for k in keys { disabledByServer.insert(k) }
        lock.unlock()
    }

    /// True for the `200` no-op body of a switched-off feature.
    static func isFeatureDisabledBody(_ j: JSONObject?) -> Bool {
        guard let j = j, j.str("reason") == "feature_disabled", let accepted = j.bool("accepted") else { return false }
        return !accepted
    }
}
