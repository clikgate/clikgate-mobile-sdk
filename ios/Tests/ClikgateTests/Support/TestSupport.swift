import Foundation
import XCTest
@testable import Clikgate

// MARK: - Fixtures (shared/fixtures, loaded from the repo — never duplicated by hand)

enum Fixtures {
    static let directory: URL = {
        // ios/Tests/ClikgateTests/Support/TestSupport.swift -> repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/fixtures", isDirectory: true)
    }()

    static func data(_ name: String) -> Data {
        let url = directory.appendingPathComponent("\(name).json")
        guard let d = try? Data(contentsOf: url) else { fatalError("Missing fixture \(url.path)") }
        return d
    }

    static func json(_ name: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data(name))) as? [String: Any] ?? [:]
    }
}

// MARK: - URLProtocol stub server

struct StubResponse {
    var status: Int
    var body: Data
    var headers: [String: String] = [:]
    var networkError: URLError? = nil

    static func fixture(_ name: String, status: Int = 200, headers: [String: String] = [:]) -> StubResponse {
        StubResponse(status: status, body: Fixtures.data(name), headers: headers)
    }
    static func json(_ s: String, status: Int = 200) -> StubResponse { StubResponse(status: status, body: Data(s.utf8)) }
    static let ok = StubResponse.json(#"{"ok": true}"#)
    static func offline() -> StubResponse { StubResponse(status: 0, body: Data(), networkError: URLError(.notConnectedToInternet)) }
}

struct RecordedRequest {
    var method: String
    var path: String
    var query: String?
    var headers: [String: String]
    var body: Data?

    var json: [String: Any] { body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }
    var key: String { "\(method) \(path)" }
}

final class StubServer: @unchecked Sendable {
    static let shared = StubServer()
    private let lock = NSLock()
    private var routes: [String: [StubResponse]] = [:]
    private var _requests: [RecordedRequest] = []

    func reset() {
        lock.lock(); routes = [:]; _requests = []; lock.unlock()
    }

    /// Responses are served in order; the last one repeats.
    func on(_ key: String, _ responses: StubResponse...) {
        lock.lock(); routes[key] = responses; lock.unlock()
    }

    var requests: [RecordedRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    func requests(_ key: String) -> [RecordedRequest] { requests.filter { $0.key == key } }

    func respond(to request: URLRequest) -> StubResponse {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: 4096)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            buf.deallocate()
            stream.close()
            body = data
        }
        let url = request.url!
        let rec = RecordedRequest(method: request.httpMethod ?? "GET", path: url.path, query: url.query,
                                  headers: request.allHTTPHeaderFields ?? [:], body: body)
        lock.lock()
        _requests.append(rec)
        var response = StubResponse.json(#"{"error":{"type":"not_found","code":"not_stubbed","message":"no stub"}}"#, status: 404)
        if var list = routes[rec.key], !list.isEmpty {
            response = list[0]
            if list.count > 1 { list.removeFirst(); routes[rec.key] = list }
        }
        lock.unlock()
        return response
    }
}

final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let r = StubServer.shared.respond(to: request)
        if let e = r.networkError {
            client?.urlProtocol(self, didFailWithError: e)
            return
        }
        var headers = r.headers
        headers["Content-Type"] = "application/json"
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - Fakes

final class FakeClock: ClikgateClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var _sleeps: [Double] = []

    init(_ start: Date = Date(timeIntervalSince1970: 1_760_954_400)) { current = start }

    func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ s: Double) { lock.lock(); current = current.addingTimeInterval(s); lock.unlock() }
    var sleeps: [Double] { lock.lock(); defer { lock.unlock() }; return _sleeps }

    /// Sleeps return immediately (after yielding) and advance the clock.
    func sleep(seconds: Double) async {
        record(seconds)
        await Task.yield()
    }

    private func record(_ seconds: Double) {
        lock.lock(); _sleeps.append(seconds); current = current.addingTimeInterval(seconds); lock.unlock()
    }
}

final class FakeKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    var value: String?
    init(_ v: String? = nil) { value = v }
    func readInstallationId() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func writeInstallationId(_ id: String) { lock.lock(); value = id; lock.unlock() }
}

final class FakePasteboard: PasteboardReading, @unchecked Sendable {
    var detect: Bool?
    var strings: Bool
    var text: String?
    private(set) var reads = 0
    private(set) var detections = 0

    init(detect: Bool? = true, hasStrings: Bool = true, text: String? = nil) {
        self.detect = detect; strings = hasStrings; self.text = text
    }
    func probablyHasWebURL() async -> Bool? { detections += 1; return detect }
    func hasStrings() async -> Bool { strings }
    func readString() async -> String? { reads += 1; return text }
}

/// Device values matching shared/fixtures/install_request_ios.json.
struct FakeDevice: DeviceInfoProviding {
    var isSimulator = false
    func collect() async -> DeviceInfo {
        DeviceInfo(appVersion: "3.4.1", osVersion: "18.1", deviceModel: "iPhone15,2", locale: "en-NG",
                   timezone: "Africa/Lagos", isSimulator: isSimulator)
    }
}

/// Firebase Analytics stand-in (present or absent).
final class FakeFirebase: FirebaseAnalyticsBridging, @unchecked Sendable {
    private let lock = NSLock()
    var available: Bool
    var instanceId: String?
    private(set) var events: [(String, [String: Any])] = []
    private(set) var userProperties: [String: String?] = [:]
    init(available: Bool = false, instanceId: String? = nil) { self.available = available; self.instanceId = instanceId }
    var isAvailable: Bool { available }
    func logEvent(_ name: String, parameters: [String: Any]) { lock.lock(); events.append((name, parameters)); lock.unlock() }
    func setUserProperty(_ value: String?, forName name: String) { lock.lock(); userProperties[name] = value; lock.unlock() }
    func appInstanceID() -> String? { lock.lock(); defer { lock.unlock() }; return instanceId }
}

final class FakeDeviceCheck: DeviceCheckProviding, @unchecked Sendable {
    var isSupported: Bool
    var value: String?
    private(set) var calls = 0
    init(supported: Bool = false, token: String? = "ZGV2aWNlY2hlY2stdG9rZW4=") { isSupported = supported; value = token }
    func token() async -> String? { calls += 1; return isSupported ? value : nil }
}

final class FakeODM: OnDeviceMeasurementProviding, @unchecked Sendable {
    var isAvailable: Bool
    var info: String?
    private(set) var firstLaunchDates: [Date] = []
    init(available: Bool = false, info: String? = "abcdEfadGdaf") { isAvailable = available; self.info = info }
    func installInfo(firstLaunch: Date) async -> (info: String, sdkVersion: String?)? {
        firstLaunchDates.append(firstLaunch)
        return info.map { ($0, "3.7.0") }
    }
}

final class FakeTracking: TrackingAuthorizationProviding, @unchecked Sendable {
    var notDeterminedChecks = 0
    var undeterminedFor: Int
    init(undeterminedFor: Int = 0) { self.undeterminedFor = undeterminedFor }
    func isNotDetermined() -> Bool { notDeterminedChecks += 1; return notDeterminedChecks <= undeterminedFor }
    func isAuthorized() -> Bool { false }
}

/// AdServices: returns `tokens[i]` on the i-th call (the last one repeats) and counts the calls.
final class FakeSearchAds: SearchAdsTokenProviding, @unchecked Sendable {
    private let lock = NSLock()
    var tokens: [String] = []
    private(set) var calls = 0
    func attributionToken() -> String? {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return tokens.isEmpty ? nil : tokens[min(calls - 1, tokens.count - 1)]
    }
}

final class FakeAppAttest: AppAttesting, @unchecked Sendable {
    var isSupported: Bool
    private(set) var hashes: [Data] = []
    private(set) var generated = 0
    private(set) var assertions = 0
    init(supported: Bool = false) { isSupported = supported }
    func generateKey() async throws -> String { generated += 1; return "a2V5LWlk" }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { hashes.append(clientDataHash); return Data("attestation".utf8) }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { assertions += 1; hashes.append(clientDataHash); return Data("assertion".utf8) }
}

struct ImmediateBackground: BackgroundTaskRunning {
    func run(name: String, _ work: @escaping @Sendable () async -> Void) { Task { await work() } }
}

// MARK: - Harness

final class Harness: @unchecked Sendable {
    let dir: URL
    let clock = FakeClock()
    let keychain: FakeKeychain
    let pasteboard: FakePasteboard
    let attest: FakeAppAttest
    let tracking: FakeTracking
    let searchAds = FakeSearchAds()
    var searchAdsToken: String? {
        get { searchAds.tokens.first }
        set { searchAds.tokens = newValue.map { [$0] } ?? [] }
    }
    var device = FakeDevice()
    let dispatcher = DeepLinkDispatcher()
    var browser = FakeBrowser()
    let logger = ClikgateLogger(level: .none)
    var firebase = FakeFirebase()
    var deviceCheck = FakeDeviceCheck()
    var odm = FakeODM()
    var vendorId: String? = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
    private var uuidCounter = 0
    private let uuidLock = NSLock()

    init(keychain: String? = nil, pasteboard: FakePasteboard = FakePasteboard(detect: false),
         attest: FakeAppAttest = FakeAppAttest(), tracking: FakeTracking = FakeTracking(), dir: URL? = nil) {
        self.dir = dir ?? FileManager.default.temporaryDirectory.appendingPathComponent("clikgate-tests-\(UUID().uuidString)")
        self.keychain = FakeKeychain(keychain)
        self.pasteboard = pasteboard
        self.attest = attest
        self.tracking = tracking
    }

    func nextUUID() -> String {
        uuidLock.lock(); defer { uuidLock.unlock() }
        uuidCounter += 1
        return String(format: "00000000-0000-4000-8000-%012d", uuidCounter)
    }

    func deps() -> ClikgateDependencies {
        ClikgateDependencies(
            transport: URLSessionTransport(session: StubURLProtocol.session()),
            clock: clock, keychain: keychain, pasteboard: pasteboard, device: device,
            tracking: tracking, searchAds: searchAds,
            appAttest: attest, background: ImmediateBackground(),
            apnsEnvironment: { "sandbox" }, appURLSchemes: ["myapp"], storageDirectory: dir,
            uuid: { [unowned self] in self.nextUUID() }, jitter: { 0 },
            firebase: firebase, deviceCheck: deviceCheck, onDeviceMeasurement: odm,
            vendorId: { [vendorId] in vendorId }, browser: browser)
    }

    /// Tests default to `.automatic` pasteboard reads (the SDK default is `.off` since 1.2.0).
    func makeCore(options: ClikgateOptions = ClikgateOptions(linkDomains: ["inv.myapp.com"], logLevel: .none, pasteboardMode: .automatic),
                  wrapper: WrapperInfo? = nil, sdkKey: String = "cg_sdk_test") -> ClikgateCore {
        ClikgateCore(sdkKey: sdkKey, options: options, deps: deps(), logger: logger, dispatcher: dispatcher,
                     linkDomains: LinkDomainsBox(optionDomains: options.linkDomains), wrapper: wrapper)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dir) }
}

extension XCTestCase {
    func stubHappyPath(install: String = "install_response_organic") {
        let s = StubServer.shared
        s.on("GET /v1/sdk/config", .fixture("config_response"))
        s.on("POST /v1/sdk/install", .fixture(install))
        s.on("POST /v1/sdk/open", .json(#"{"open_id":"aop_1","uninstall_status":"installed"}"#))
        s.on("POST /v1/sdk/goals", .fixture("goals_response"))
        s.on("POST /v1/sdk/identify", .fixture("identify_response"))
        s.on("POST /v1/sdk/push-token", .ok)
        s.on("POST /v1/sdk/opt-out", .json(#"{"opt_out": true}"#))
        s.on("POST /v1/sdk/resolve", .fixture("resolve_response_matched"))
    }

    /// Registers a collecting handler on the dispatcher.
    func collect(_ d: DeepLinkDispatcher) -> ResultBox {
        let box = ResultBox()
        d.setHandler { r in box.append(r) }
        return box
    }

    /// Polls (real time) until `condition` holds.
    func eventually(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("Condition not met in \(timeout) s", file: file, line: line); return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Lets main-queue deliveries run.
    func drainMain() async {
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 20_000_000) }
    }
}

final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [ClikgateDeepLinkResult] = []
    func append(_ r: ClikgateDeepLinkResult) { lock.lock(); _items.append(r); lock.unlock() }
    var items: [ClikgateDeepLinkResult] { lock.lock(); defer { lock.unlock() }; return _items }
}

/// Records the URLs the SDK asked to show in the in-app browser.
final class FakeBrowser: BrowserPresenting, @unchecked Sendable {
    private let lock = NSLock()
    private var _opened: [URL] = []
    var succeeds = true
    private var _external: [URL] = []
    @MainActor func open(_ url: URL) -> Bool { lock.lock(); _opened.append(url); lock.unlock(); return succeeds }
    @MainActor func openExternal(_ url: URL) { lock.lock(); _external.append(url); lock.unlock() }
    var opened: [URL] { lock.lock(); defer { lock.unlock() }; return _opened }
    /// URLs sent to the system browser (Change 17 password links).
    var external: [URL] { lock.lock(); defer { lock.unlock() }; return _external }
}
