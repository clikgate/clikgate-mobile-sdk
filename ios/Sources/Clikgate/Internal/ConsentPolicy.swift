import Foundation

// Consent and policy helpers: consent regions, Google click ids, the version policy, Firebase
// limits and the injectable providers for Firebase, DeviceCheck, IDFV and Google on-device
// measurement.

/// Consent regions. `EEA` covers the 27 EU member states plus Iceland, Liechtenstein and
/// Norway; `UK` matches `GB`; any other code matches itself.
enum ConsentRegions {
    static let eea = [
        "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE", "IT",
        "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE", "IS", "LI", "NO",
    ]
    static let defaultRequired = ["EEA", "UK", "CH"]

    /// Uppercased, trimmed hint, or nil when it isn't `EEA`, `UK` or two letters A–Z.
    static func normalize(_ region: String?) -> String? {
        guard let r = region?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !r.isEmpty else { return nil }
        if r == "EEA" || r == "UK" { return r }
        guard r.count == 2, r.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else { return nil }
        return r
    }

    static func matches(_ hint: String, _ regions: [String]) -> Bool {
        regions.contains { raw in
            let r = raw.uppercased()
            if r == hint { return true }
            if r == "EEA" { return eea.contains(hint) }
            if r == "UK" || r == "GB" { return hint == "UK" || hint == "GB" }
            return false
        }
    }
}

/// `gclid` / `gbraid` / `wbraid` from a URL query.
struct GoogleClickIds: Sendable, Equatable {
    var gclid: String?
    var gbraid: String?
    var wbraid: String?

    var isEmpty: Bool { gclid == nil && gbraid == nil && wbraid == nil }

    static func parse(_ url: URL?) -> GoogleClickIds? {
        guard let url = url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? {
            guard let v = items.first(where: { $0.name == name })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !v.isEmpty, v.count <= 512 else { return nil }
            return v
        }
        let ids = GoogleClickIds(gclid: value("gclid"), gbraid: value("gbraid"), wbraid: value("wbraid"))
        return ids.isEmpty ? nil : ids
    }

    init(gclid: String? = nil, gbraid: String? = nil, wbraid: String? = nil) {
        self.gclid = gclid; self.gbraid = gbraid; self.wbraid = wbraid
    }

    init?(json j: JSONObject?) {
        guard let j = j else { return nil }
        gclid = j.str("gclid"); gbraid = j.str("gbraid"); wbraid = j.str("wbraid")
        if isEmpty { return nil }
    }

    func json(source: String) -> JSONObject {
        ["gclid": gclid ?? NSNull(), "gbraid": gbraid ?? NSNull(), "wbraid": wbraid ?? NSNull(), "source": source]
    }
}

/// Semantic version comparison (`1.2.0` < `1.10.0`); pre-release / build suffixes are ignored.
enum SemVer {
    static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] {
            let core = s.components(separatedBy: CharacterSet(charactersIn: "-+"))[0]
            return core.components(separatedBy: ".").map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}

/// SDK call names of `blocked_instructions.allowed_calls` for a request path.
enum SDKCall {
    static let blockedDefault = ["config", "install", "open", "events", "opt_out", "consent", "install_ping"]

    static func name(path: String) -> String {
        var p = path
        if p.hasPrefix("/") { p.removeFirst() }
        if p.hasPrefix("v1/sdk/") { p.removeFirst("v1/sdk/".count) }
        let first = p.components(separatedBy: "/")[0]
        switch first {
        case "install-ping": return "install_ping"
        case "push-token": return "push_token"
        case "opt-out": return "opt_out"
        case "apple-search-ads": return "apple_search_ads"
        case "deeplink-handled": return "deeplink_handled"
        default: return first
        }
    }
}

/// Google Analytics / Firebase limits (checked 2026-10-22, FIRAnalytics.h 13.0.1 and GA4 docs).
enum FirebaseLimits {
    static let maxNameLength = 40
    static let maxParams = 25
    static let maxStringValue = 100
    static let maxUserPropertyName = 24
    static let maxUserPropertyValue = 36
    static let reservedPrefixes = ["firebase_", "google_", "ga_"]

    static func isValidName(_ name: String, maxLength: Int = maxNameLength) -> Bool {
        guard (1...maxLength).contains(name.count), let first = name.unicodeScalars.first,
              ("a"..."z").contains(first) || ("A"..."Z").contains(first) else { return false }
        guard name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" })
        else { return false }
        let lower = name.lowercased()
        return !reservedPrefixes.contains { lower.hasPrefix($0) }
    }

    static func truncate(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n)) }

    /// Currencies without minor units (ISO 4217 exponent 0) that Clikgate customers are likely to use.
    static let zeroDecimal = ["JPY", "KRW", "UGX", "RWF", "XAF", "XOF", "VND", "CLP", "ISK", "PYG", "GNF", "KMF", "BIF", "DJF", "VUV", "XPF"]

    static func majorUnits(_ money: ClikgateMoney) -> Double {
        zeroDecimal.contains(money.currency) ? Double(money.amountMinor) : Double(money.amountMinor) / 100
    }

    /// Scalar properties as Firebase parameters (strings truncated, booleans as 0/1, maps/lists dropped).
    static func parameters(from props: [String: JSONValue]?, revenue: ClikgateMoney?) -> [String: Any] {
        var out: [String: Any] = [:]
        if let r = revenue { out["value"] = majorUnits(r); out["currency"] = r.currency }
        for (key, v) in props ?? [:] {
            guard out.count < maxParams, out[key] == nil, isValidName(key) else { continue }
            switch v {
            case .string(let s): out[key] = truncate(s, maxStringValue)
            case .int(let i): out[key] = NSNumber(value: i)
            case .double(let d): out[key] = d
            case .bool(let b): out[key] = b ? 1 : 0
            default: continue
            }
        }
        return out
    }
}

// MARK: - Synchronous snapshot (facade reads without awaiting the actor)

/// What the facade answers synchronously (`getConsent`, `attributionMetadata`). Written by the core.
final class SyncSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var _consent = ClikgateConsent()
    private var _metadata: [String: String] = [:]

    var consent: ClikgateConsent {
        get { lock.lock(); defer { lock.unlock() }; return _consent }
        set { lock.lock(); _consent = newValue; lock.unlock() }
    }

    var metadata: [String: String] {
        get { lock.lock(); defer { lock.unlock() }; return _metadata }
        set { lock.lock(); _metadata = newValue; lock.unlock() }
    }
}

// MARK: - Providers (injectable)

/// Firebase Analytics, looked up at runtime (no dependency).
protocol FirebaseAnalyticsBridging: Sendable {
    var isAvailable: Bool { get }
    func logEvent(_ name: String, parameters: [String: Any])
    func setUserProperty(_ value: String?, forName name: String)
    /// nil when Firebase's analytics storage consent is denied or the id isn't known yet.
    func appInstanceID() -> String?
}

/// `FIRAnalytics` class methods through the Objective-C runtime.
struct SystemFirebaseAnalytics: FirebaseAnalyticsBridging {
    private var cls: AnyObject? { NSClassFromString("FIRAnalytics") }

    var isAvailable: Bool {
        guard let c = cls else { return false }
        return c.responds(to: NSSelectorFromString("logEventWithName:parameters:"))
    }

    func logEvent(_ name: String, parameters: [String: Any]) {
        guard let c = cls else { return }
        _ = c.perform(NSSelectorFromString("logEventWithName:parameters:"), with: name, with: parameters as NSDictionary)
    }

    func setUserProperty(_ value: String?, forName name: String) {
        guard let c = cls else { return }
        _ = c.perform(NSSelectorFromString("setUserPropertyString:forName:"), with: value, with: name)
    }

    func appInstanceID() -> String? {
        let sel = NSSelectorFromString("appInstanceID")
        guard let c = cls, c.responds(to: sel) else { return nil }
        return c.perform(sel)?.takeUnretainedValue() as? String
    }
}

/// Apple DeviceCheck (`DCDevice`) token.
protocol DeviceCheckProviding: Sendable {
    var isSupported: Bool { get }
    /// Base64 token, nil on failure.
    func token() async -> String?
}

/// Google's on-device conversion measurement SDK (`GoogleAdsOnDeviceConversion`).
protocol OnDeviceMeasurementProviding: Sendable {
    var isAvailable: Bool { get }
    /// The aggregate conversion info for the installation, nil when unavailable (or after the timeout).
    func installInfo(firstLaunch: Date) async -> (info: String, sdkVersion: String?)?
}

/// `ODCConversionManager` through the Objective-C runtime (header of GoogleAdsOnDeviceConversion 3.7.0):
/// `+sharedInstance`, `-versionString`, `-setFirstLaunchTime:` and
/// `-fetchAggregateConversionInfoForInteraction:completion:` (ODCInteractionTypeInstallation = 0;
/// the completion runs on a global concurrent queue; both nil = not available).
struct SystemOnDeviceMeasurement: OnDeviceMeasurementProviding {
    var timeout: Double = 3

    private var manager: NSObject? {
        guard let cls: AnyObject = NSClassFromString("ODCConversionManager") else { return nil }
        let sel = NSSelectorFromString("sharedInstance")
        guard cls.responds(to: sel) else { return nil }
        return cls.perform(sel)?.takeUnretainedValue() as? NSObject
    }

    var isAvailable: Bool { manager != nil }

    func installInfo(firstLaunch: Date) async -> (info: String, sdkVersion: String?)? {
        guard let m = manager else { return nil }
        let setSel = NSSelectorFromString("setFirstLaunchTime:")
        if m.responds(to: setSel) { _ = m.perform(setSel, with: firstLaunch as NSDate) }
        let fetchSel = NSSelectorFromString("fetchAggregateConversionInfoForInteraction:completion:")
        guard m.responds(to: fetchSel) else { return nil }
        let version = m.responds(to: NSSelectorFromString("versionString")) ? m.value(forKey: "versionString") as? String : nil
        typealias Fetch = @convention(c) (NSObject, Selector, Int, @escaping @convention(block) (NSString?, NSError?) -> Void) -> Void
        let fetch = unsafeBitCast(m.method(for: fetchSel), to: Fetch.self)
        let once = ResumeOnce<String?>()
        let info: String? = await withCheckedContinuation { c in
            once.set(c)
            fetch(m, fetchSel, 0) { info, _ in once.resume(info.map { String($0) }) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        }
        guard let s = info, !s.isEmpty else { return nil }
        return (s, version)
    }
}

/// Resumes a continuation at most once (completion vs timeout).
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var c: CheckedContinuation<T, Never>?
    private var pending: T?
    private var done = false

    func set(_ c: CheckedContinuation<T, Never>) {
        lock.lock()
        if done, let p = pending { lock.unlock(); c.resume(returning: p); return }
        self.c = c
        lock.unlock()
    }

    func resume(_ v: T) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        if let c = c { self.c = nil; lock.unlock(); c.resume(returning: v); return }
        pending = v
        lock.unlock()
    }
}
