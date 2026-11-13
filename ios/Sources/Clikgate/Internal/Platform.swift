import Foundation
import Security
import UIKit
import SafariServices
#if canImport(AdServices)
import AdServices
#endif
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif
#if canImport(DeviceCheck)
import DeviceCheck
#endif

// Live implementations of the dependency protocols.

final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession) { self.session = session }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10   // contract: 10 s connect + 10 s read
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error { continuation.resume(throwing: error); return }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: URLError(.badServerResponse)); return
                }
                continuation.resume(returning: (data ?? Data(), http))
            }
            task.resume()
        }
    }
}

struct SystemClock: ClikgateClock {
    func now() -> Date { Date() }
    func sleep(seconds: Double) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Keychain item `com.clikgate.installation-id`: AfterFirstUnlock, never synchronised to iCloud.
/// Keychain items survive app deletion, which is what makes reinstall detection work.
struct SystemKeychain: KeychainStoring {
    static let service = "com.clikgate.installation-id"
    static let account = "installation_id"

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    func readInstallationId() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func writeInstallationId(_ id: String) {
        let data = Data(id.utf8)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(baseQuery() as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery()
            add.merge(attrs) { $1 }
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

struct SystemPasteboard: PasteboardReading {
    func probablyHasWebURL() async -> Bool? {
        if #available(iOS 15.0, *) {
            return await Self.detectWebURL15()
        } else if #available(iOS 14.0, *) {
            return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                DispatchQueue.main.async {
                    UIPasteboard.general.detectPatterns(for: [UIPasteboard.DetectionPattern.probableWebURL]) { result in
                        switch result {
                        case .success(let patterns): c.resume(returning: patterns.contains(.probableWebURL))
                        case .failure: c.resume(returning: false)
                        }
                    }
                }
            }
        }
        return nil
    }

    @available(iOS 15.0, *)
    @MainActor
    private static func detectWebURL15() async -> Bool {
        let key: PartialKeyPath<UIPasteboard.DetectedValues> = \UIPasteboard.DetectedValues.probableWebURL
        let found = (try? await UIPasteboard.general.detectedPatterns(for: [key])) ?? []
        return found.contains(key)
    }

    func hasStrings() async -> Bool {
        await MainActor.run { UIPasteboard.general.hasStrings }
    }

    func readString() async -> String? {
        await MainActor.run { UIPasteboard.general.string }
    }
}

struct SystemDeviceInfo: DeviceInfoProviding {
    func collect() async -> DeviceInfo {
        let osVersion = await MainActor.run { UIDevice.current.systemVersion }
        return DeviceInfo(
            appVersion: BundleInfo.appVersion(),
            osVersion: osVersion,
            deviceModel: Self.modelIdentifier(),
            locale: Self.localeIdentifier(),
            timezone: TimeZone.current.identifier,
            isSimulator: Self.isSimulator
        )
    }

    static func identifierForVendor() async -> String? {
        await MainActor.run { UIDevice.current.identifierForVendor?.uuidString }
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    static func modelIdentifier() -> String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        // `machine` is a fixed-size C array (a tuple in Swift): read it as a NUL-terminated string
        let id = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return id.isEmpty ? "iPhone" : id
    }

    /// BCP 47-ish `language-REGION` (`en-NG`).
    static func localeIdentifier(_ locale: Locale = .current) -> String? {
        guard let lang = locale.languageCode else { return nil }
        if let region = locale.regionCode { return "\(lang)-\(region)" }
        return lang
    }
}

/// Apple DeviceCheck (iOS 11+): an ephemeral token the backend exchanges with Apple for the
/// per-device bits.
struct SystemDeviceCheck: DeviceCheckProviding {
    var isSupported: Bool {
        #if canImport(DeviceCheck)
        return DCDevice.current.isSupported
        #else
        return false
        #endif
    }

    func token() async -> String? {
        #if canImport(DeviceCheck)
        guard DCDevice.current.isSupported else { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            DCDevice.current.generateToken { data, _ in c.resume(returning: data?.base64EncodedString()) }
        }
        #else
        return nil
        #endif
    }
}

struct SystemTrackingAuthorization: TrackingAuthorizationProviding {
    func isNotDetermined() -> Bool {
        #if canImport(AppTrackingTransparency)
        if #available(iOS 14.0, *) { return ATTrackingManager.trackingAuthorizationStatus == .notDetermined }
        #endif
        return false
    }

    func isAuthorized() -> Bool {
        #if canImport(AppTrackingTransparency)
        if #available(iOS 14.0, *) { return ATTrackingManager.trackingAuthorizationStatus == .authorized }
        #endif
        return false
    }
}

struct SystemSearchAds: SearchAdsTokenProviding {
    func attributionToken() -> String? {
        #if canImport(AdServices)
        if #available(iOS 14.3, *) { return try? AAAttribution.attributionToken() }
        #endif
        return nil
    }
}

struct SystemAppAttest: AppAttesting {
    var isSupported: Bool {
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, *) { return DCAppAttestService.shared.isSupported }
        #endif
        return false
    }

    func generateKey() async throws -> String {
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, *) { return try await DCAppAttestService.shared.generateKey() }
        #endif
        throw ClikgateError(code: "attestation_unavailable", message: "App Attest unavailable")
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, *) { return try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash) }
        #endif
        throw ClikgateError(code: "attestation_unavailable", message: "App Attest unavailable")
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, *) { return try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash) }
        #endif
        throw ClikgateError(code: "attestation_unavailable", message: "App Attest unavailable")
    }
}

@MainActor
private final class BackgroundTaskBox {
    var id: UIBackgroundTaskIdentifier = .invalid
}

struct SystemBackgroundTasks: BackgroundTaskRunning {
    func run(name: String, _ work: @escaping @Sendable () async -> Void) {
        Task { @MainActor in
            let box = BackgroundTaskBox()
            let app = UIApplication.shared
            box.id = app.beginBackgroundTask(withName: name) {
                // Expiration: end the task; queued work stays persisted and is retried on next start.
                if box.id != .invalid { app.endBackgroundTask(box.id); box.id = .invalid }
            }
            Task {
                await work()
                await MainActor.run {
                    if box.id != .invalid { app.endBackgroundTask(box.id); box.id = .invalid }
                }
            }
        }
    }
}

/// SFSafariViewController over the top view controller for shared-domain links. Not `UIApplication.open`: iOS
/// could hand the Universal Link straight back to this app.
struct SystemBrowser: BrowserPresenting {
    @MainActor func open(_ url: URL) -> Bool {
        var top: UIViewController?
        for case let scene as UIWindowScene in (UIApplication.shared.connectedScenes as NSSet).allObjects {
            for w in scene.windows where w.isKeyWindow { top = w.rootViewController }
        }
        while let p = top?.presentedViewController { top = p }
        guard let vc = top else { return false }
        vc.present(SFSafariViewController(url: url), animated: true)
        return true
    }

    /// A password link's page in the system browser (Safari keeps the password cookie for the redirect
    /// that follows). Whether iOS opens Safari or hands the app's own Universal Link straight back is not documented,
    /// so `DeepLinkDispatcher.handOff` opens one URL at most once per 30 s: no loop either way. Check on a device
    /// (TESTING_DEEP_LINKS.md).
    @MainActor func openExternal(_ url: URL) { UIApplication.shared.open(url) }
}

struct SystemRemoteNotifications: RemoteNotificationRegistering {
    @MainActor func register() {
        guard !Bundle.main.bundlePath.hasSuffix(".appex") else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }
}

/// Reads `aps-environment` from the embedded provisioning profile (development builds, ad hoc,
/// TestFlight-less builds). App Store builds have no embedded profile and always use production.
enum ProvisioningProfile {
    static func apsEnvironment(bundle: Bundle = .main) -> String {
        #if targetEnvironment(simulator)
        // Simulator builds carry no profile; simulator device tokens are sandbox tokens.
        return "sandbox"
        #else
        guard let path = bundle.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = FileManager.default.contents(atPath: path) else { return "production" }
        return parseApsEnvironment(profileData: data)
        #endif
    }

    /// The profile is a CMS-signed plist; the XML plist is embedded verbatim. Reads the value after the
    /// `aps-environment` key (in `Entitlements`, the only place the key appears).
    static func parseApsEnvironment(profileData data: Data) -> String {
        guard let text = String(data: data, encoding: .isoLatin1),
              let key = text.range(of: "<key>aps-environment</key>") else { return "production" }
        let value = text[key.upperBound...].prefix(120)
        guard let s = value.range(of: "<string>") else { return "production" }
        return value[s.upperBound...].hasPrefix("development") ? "sandbox" : "production"
    }
}
