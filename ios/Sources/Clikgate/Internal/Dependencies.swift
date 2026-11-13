import Foundation

// Everything the core touches outside its own memory goes through one of these protocols,
// so tests can substitute fakes (URLProtocol stub session, mocked Keychain, pasteboard, clock...).

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

protocol ClikgateClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async
}

protocol KeychainStoring: Sendable {
    func readInstallationId() -> String?
    func writeInstallationId(_ id: String)
}

protocol PasteboardReading: Sendable {
    /// nil when detection isn't available (iOS 13); otherwise whether a web URL is likely present.
    /// Must not trigger the paste prompt.
    func probablyHasWebURL() async -> Bool?
    /// iOS 13 fallback check (metadata only).
    func hasStrings() async -> Bool
    /// Reads the string (iOS 16+ shows the system paste prompt).
    func readString() async -> String?
}

struct DeviceInfo: Sendable {
    var appVersion: String
    var osVersion: String
    var deviceModel: String
    var locale: String?
    var timezone: String?
    /// Compile-time Simulator flag (`is_emulator`). No other device probes.
    var isSimulator: Bool
}


protocol DeviceInfoProviding: Sendable {
    func collect() async -> DeviceInfo
}

protocol TrackingAuthorizationProviding: Sendable {
    /// True while the ATT status is `.notDetermined` (always false before iOS 14).
    func isNotDetermined() -> Bool
    /// True when ATT status is `.authorized`.
    func isAuthorized() -> Bool
}

protocol SearchAdsTokenProviding: Sendable {
    func attributionToken() -> String?
}

protocol AppAttesting: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

protocol BrowserPresenting: Sendable {
    /// Shows `url` in an in-app browser; false when it couldn't (no window to present from).
    @MainActor func open(_ url: URL) -> Bool
    /// Opens `url` in the system browser (password links).
    @MainActor func openExternal(_ url: URL)
}

protocol BackgroundTaskRunning: Sendable {
    /// Runs `work` inside a background-task window (so it can finish after the app is backgrounded).
    func run(name: String, _ work: @escaping @Sendable () async -> Void)
}

protocol RemoteNotificationRegistering: Sendable {
    /// `UIApplication.registerForRemoteNotifications()` (no permission prompt); no-op in app extensions.
    @MainActor func register()
}

struct ClikgateDependencies: Sendable {
    var transport: HTTPTransport
    var clock: ClikgateClock
    var keychain: KeychainStoring
    var pasteboard: PasteboardReading
    var device: DeviceInfoProviding
    var tracking: TrackingAuthorizationProviding
    var searchAds: SearchAdsTokenProviding
    var appAttest: AppAttesting
    var background: BackgroundTaskRunning
    /// `production` / `sandbox` from the embedded provisioning profile's `aps-environment`.
    var apnsEnvironment: @Sendable () -> String
    /// URL schemes the app registered (CFBundleURLTypes).
    var appURLSchemes: [String]
    /// Directory for state.json and events.json (Application Support/Clikgate).
    var storageDirectory: URL
    /// Random UUID source (injectable for deterministic tests).
    var uuid: @Sendable () -> String
    /// Retry jitter in [-1, 1] (scaled to ±20 %).
    var jitter: @Sendable () -> Double
    // Providers (runtime-detected, no dependency).
    var firebase: FirebaseAnalyticsBridging = SystemFirebaseAnalytics()
    var deviceCheck: DeviceCheckProviding = SystemDeviceCheck()
    var onDeviceMeasurement: OnDeviceMeasurementProviding = SystemOnDeviceMeasurement()
    /// `UIDevice.identifierForVendor`.
    var vendorId: @Sendable () async -> String? = { await SystemDeviceInfo.identifierForVendor() }
    /// In-app browser for unmatched shared-domain links (SFSafariViewController).
    var browser: BrowserPresenting = SystemBrowser()
    /// APNs registration for uninstall checks (`automaticPushToken`).
    var remoteNotifications: RemoteNotificationRegistering = SystemRemoteNotifications()

    static func live() -> ClikgateDependencies {
        ClikgateDependencies(
            transport: URLSessionTransport(session: URLSessionTransport.makeSession()),
            clock: SystemClock(),
            keychain: SystemKeychain(),
            pasteboard: SystemPasteboard(),
            device: SystemDeviceInfo(),
            tracking: SystemTrackingAuthorization(),
            searchAds: SystemSearchAds(),
            appAttest: SystemAppAttest(),
            background: SystemBackgroundTasks(),
            apnsEnvironment: { ProvisioningProfile.apsEnvironment() },
            appURLSchemes: BundleInfo.urlSchemes(),
            storageDirectory: StorageLocation.defaultDirectory(),
            uuid: { UUID().uuidString.lowercased() },
            jitter: { Double.random(in: -1...1) }
        )
    }
}

enum StorageLocation {
    static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Clikgate", isDirectory: true)
    }
}

enum BundleInfo {
    static func urlSchemes(_ bundle: Bundle = .main) -> [String] {
        guard let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else { return [] }
        return types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }.map { $0.lowercased() }
    }

    static func appVersion(_ bundle: Bundle = .main) -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }
}
