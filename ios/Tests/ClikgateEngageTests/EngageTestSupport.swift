import Foundation
import UIKit
import XCTest
@_spi(ClikgateEngage) import Clikgate
@testable import ClikgateEngage

enum EFixtures {
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("shared/fixtures", isDirectory: true)

    static func data(_ name: String) -> Data {
        let url = directory.appendingPathComponent("\(name).json")
        guard let d = try? Data(contentsOf: url) else { fatalError("Missing fixture \(url.path)") }
        return d
    }

    static func json(_ name: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data(name))) as? [String: Any] ?? [:]
    }
}

/// A fake core SDK: feature switches, a request context (or an error) and recorded reports.
final class FakeHost: EngageHost, @unchecked Sendable {
    private let lock = NSLock()
    var disabled: Set<String> = []
    var contextError: ClikgateError?
    var customerUserId: String? = "user_42"
    var identityToken: String? = "sig.1760954400"
    private(set) var contextCalls = 0
    private(set) var reports: [(code: String, feature: String?)] = []

    func isFeatureEnabled(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return !disabled.contains(key) }

    private(set) var noWaitCalls = 0
    /// The waiting context holds its answer (an install still on its way) until ``releaseWaiting()``.
    var holdWaiting = false
    private var held: [CheckedContinuation<Void, Never>] = []
    /// Saved links: program → (owner, link); answered only to the owner (the signed-in customer).
    private(set) var links: [String: (owner: String, link: [String: Any])] = [:]

    func releaseWaiting() {
        lock.lock(); holdWaiting = false; let h = held; held = []; lock.unlock()
        h.forEach { $0.resume() }
    }

    func requestContext(wait: Bool) async throws -> ClikgateRequestContext {
        lock.lock()
        if wait { contextCalls += 1 } else { noWaitCalls += 1 }
        let hold = wait && holdWaiting
        lock.unlock()
        if hold {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock(); held.append(c); lock.unlock()
            }
        }
        lock.lock(); let err = contextError; let user = customerUserId; let token = identityToken; lock.unlock()
        if let e = err { throw e }
        return ClikgateRequestContext(installationId: "6a1f0c2e-0000-4000-8000-000000000001", sdkKey: "cg_sdk_test_abc",
                                      environment: "production", apiBaseUrl: URL(string: "https://sdk.example.test")!,
                                      identityToken: token, customerUserId: user,
                                      sdkVersion: "flutter/1.0.0", nativeSdkVersion: "ios/1.0.0")
    }

    func savedLink(_ programId: String) -> ([String: Any]?, String?) {
        lock.lock(); defer { lock.unlock() }
        guard let o = customerUserId else { return (nil, nil) }
        guard let e = links[programId], e.owner == o else { return (nil, o) }
        return (e.link, o)
    }

    func saveLink(_ programId: String, _ object: [String: Any], token: String?) {
        lock.lock(); defer { lock.unlock() }
        guard let t = token, t == customerUserId else { return }
        links[programId] = (t, object)
    }

    func reportServerError(code: String, feature: String?) {
        lock.lock(); reports.append((code, feature)); lock.unlock()
    }
}

struct Recorded {
    var request: URLRequest
    var key: String { "\(request.httpMethod ?? "GET") \(request.url!.path)" }
    var query: String? { request.url?.query }
    var json: [String: Any] {
        request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
}

enum FakeReply {
    case json(String, status: Int = 200)
    case fixture(String, status: Int = 200)
    case offline
}

/// Routes "METHOD /path" to replies served in order (the last one repeats).
final class FakeTransport: EngageTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: [FakeReply]] = [:]
    private var _requests: [Recorded] = []

    func on(_ key: String, _ replies: FakeReply...) { lock.lock(); routes[key] = replies; lock.unlock() }
    var requests: [Recorded] { lock.lock(); defer { lock.unlock() }; return _requests }
    func requests(_ key: String) -> [Recorded] { requests.filter { $0.key == key } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let rec = Recorded(request: request)
        lock.lock()
        _requests.append(rec)
        var reply = FakeReply.json(#"{"error":{"type":"not_found","code":"not_stubbed","message":"no stub"}}"#, status: 404)
        if var list = routes[rec.key], !list.isEmpty {
            reply = list[0]
            if list.count > 1 { list.removeFirst(); routes[rec.key] = list }
        }
        lock.unlock()
        let (data, status): (Data, Int)
        switch reply {
        case .offline: throw URLError(.notConnectedToInternet)
        case .json(let s, let st): (data, status) = (Data(s.utf8), st)
        case .fixture(let n, let st): (data, status) = (EFixtures.data(n), st)
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_760_954_400)
    private(set) var sleeps: [Double] = []
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ s: Double) { lock.lock(); current = current.addingTimeInterval(s); lock.unlock() }
    func recordSleep(_ s: Double) { lock.lock(); sleeps.append(s); lock.unlock() }
}

struct EngageRig {
    let host = FakeHost()
    let transport = FakeTransport()
    let clock = TestClock()
    let client: EngageClient

    init() {
        let clock = self.clock
        client = EngageClient(host: host, transport: transport, now: { clock.now() }, sleep: { s in clock.recordSleep(s) })
    }

    var referrals: ClikgateEngageReferrals { ClikgateEngageReferrals(client: client) }
    var leaderboards: ClikgateEngageLeaderboards { ClikgateEngageLeaderboards(client: client) }
    var codes: ClikgateEngageCodes { ClikgateEngageCodes(client: client) }
}

@MainActor
final class FakeShareUI: EngageShareUI {
    var canOpenResult: Bool
    var openResult: Bool
    var canPresent: Bool
    private(set) var opened: [URL] = []
    private(set) var sheets: [[Any]] = []
    var sheetCount: Int { sheets.count }
    var firstSheetText: String? { sheets.first?.first as? String }

    init(canOpen: Bool = false, openResult: Bool = true, canPresent: Bool = true) {
        canOpenResult = canOpen; self.openResult = openResult; self.canPresent = canPresent
    }

    func canOpen(_ url: URL) -> Bool { canOpenResult }
    func open(_ url: URL) async -> Bool { opened.append(url); return openResult }
    private(set) var done: [((String?, Bool) -> Void)?] = []
    func presentShareSheet(items: [Any], from presenter: UIViewController?, done: ((String?, Bool) -> Void)?) -> Bool {
        guard canPresent else { return false }
        sheets.append(items)
        self.done.append(done)
        return true
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    func set() { lock.lock(); _value = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
}

extension XCTestCase {
    func expectEngageError<T>(_ code: String, file: StaticString = #filePath, line: UInt = #line,
                              _ work: () async throws -> T) async -> ClikgateError? {
        do {
            _ = try await work()
            XCTFail("expected \(code)", file: file, line: line)
            return nil
        } catch let e as ClikgateError {
            XCTAssertEqual(e.code, code, file: file, line: line)
            return e
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
            return nil
        }
    }

    func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("Condition not met in \(timeout) s", file: file, line: line); return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
