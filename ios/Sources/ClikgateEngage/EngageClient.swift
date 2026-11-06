import Foundation
#if !CLIKGATE_POD_SINGLE_MODULE
@_spi(ClikgateEngage) import Clikgate
#endif

/// The Engage HTTP layer: feature check, request context, identity check, 60 s read cache,
/// one retry for network errors, error decoding.
final class EngageClient: @unchecked Sendable {
    static let cacheTTL: TimeInterval = 60
    static let networkRetryDelay: Double = 0.5

    static let live = EngageClient(host: LiveEngageHost(),
                                   transport: EngageURLSessionTransport(session: EngageURLSessionTransport.defaultSession()))

    let host: EngageHost
    let transport: EngageTransport
    let now: @Sendable () -> Date
    let sleep: @Sendable (Double) async -> Void

    private let lock = NSLock()
    private var cache: [String: (storedAt: Date, value: EngageJSON)] = [:]

    init(host: EngageHost, transport: EngageTransport,
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (Double) async -> Void = { s in try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }) {
        self.host = host
        self.transport = transport
        self.now = now
        self.sleep = sleep
    }

    func clearCache() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }

    private func cached(_ key: String) -> EngageJSON? {
        lock.lock(); defer { lock.unlock() }
        guard let e = cache[key] else { return nil }
        let age = now().timeIntervalSince(e.storedAt)
        if age < 0 || age >= Self.cacheTTL { cache[key] = nil; return nil }
        return e.value
    }

    private func store(_ key: String, _ value: EngageJSON) {
        lock.lock(); cache[key] = (now(), value); lock.unlock()
    }

    /// One Engage call. `needsUser`: fails with `not_identified` (no network) when the installation
    /// isn't identified. `cacheable`: a GET whose result may be served from memory for 60 s.
    ///
    /// Non-generic on purpose (code size: one copy of the async state machine); callers decode the
    /// returned object with ``decode(_:_:)``. The cache holds the response object.
    func call(feature: String, method: String, path: String, query: [URLQueryItem] = [],
              body: [String: Any]? = nil, needsUser: Bool, cacheable: Bool) async throws -> EngageJSON {
        // An empty feature (share events) has no switch and keeps the read cache.
        guard feature.isEmpty || host.isFeatureEnabled(feature) else { throw Self.featureDisabled(feature) }
        let ctx = try await host.requestContext()
        if needsUser && ctx.customerUserId == nil {
            throw ClikgateError(code: ClikgateError.notIdentified,
                                message: "Call Clikgate.shared.identifyUser(customerId:identityToken:) first.")
        }
        let request = Self.makeRequest(ctx, method: method, path: path, query: query, body: body)
        let key = "\(ctx.installationId)|\(ctx.customerUserId ?? "")|\(ctx.identityToken == nil ? 0 : 1)|\(method) \(request.url?.absoluteString ?? path)"
        if method != "GET" && !feature.isEmpty { clearCache() }
        if cacheable, let hit = cached(key) { return hit }

        let (data, http) = try await send(request)
        if (200..<300).contains(http.statusCode) {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let j = json, Self.isFeatureDisabledBody(j) {
                let k = (j["feature"] as? String) ?? feature
                host.reportServerError(code: ClikgateError.featureDisabled, feature: k)
                if k != feature { host.reportServerError(code: ClikgateError.featureDisabled, feature: feature) }
                throw Self.featureDisabled(k)
            }
            guard let j = json else {
                throw ClikgateError(code: ClikgateError.serverError, message: "Unexpected response from \(path)", status: http.statusCode)
            }
            let value = EngageJSON(object: j)
            if cacheable { store(key, value) }
            return value
        }
        let error = Self.decodeError(data: data, status: http.statusCode)
        switch error.code {
        case ClikgateError.invalidSdkKey, ClikgateError.sdkDisabled, ClikgateError.installationUnknown:
            host.reportServerError(code: error.code, feature: nil)
        default: break
        }
        throw error
    }

    /// Sends `request`, retrying once (after 0.5 s) when the request didn't reach the server.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let first = try? await transport.send(request) { return first }
        await sleep(Self.networkRetryDelay)
        do {
            return try await transport.send(request)
        } catch {
            throw Self.networkError(error)
        }
    }

    static func networkError(_ error: Error) -> ClikgateError {
        let timedOut = (error as? URLError)?.code == .timedOut
        return ClikgateError(code: timedOut ? ClikgateError.timeout : ClikgateError.networkError, message: "Network request failed")
    }

    /// Maps a response object to a model, or `server_error` when it isn't one.
    @_semantics("optimize.sil.specialize.generic.never")
    static func decode<T>(_ json: EngageJSON, _ make: (EngageJSON) -> T?) throws -> T {
        guard let v = make(json) else {
            throw ClikgateError(code: ClikgateError.serverError, message: "Unexpected response")
        }
        return v
    }

    static func makeRequest(_ ctx: ClikgateRequestContext, method: String, path: String, query: [URLQueryItem],
                            body: [String: Any]?) -> URLRequest {
        var comps = URLComponents(url: ctx.apiBaseUrl.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in ctx.headers { req.setValue(v, forHTTPHeaderField: k) }
        if let b = body, let data = try? JSONSerialization.data(withJSONObject: b) {
            req.httpBody = data
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    static func featureDisabled(_ feature: String) -> ClikgateError {
        ClikgateError(code: ClikgateError.featureDisabled, message: "The '\(feature)' feature is switched off for this app.",
                      feature: feature)
    }

    static func isFeatureDisabledBody(_ j: [String: Any]) -> Bool {
        (j["reason"] as? String) == "feature_disabled" && (j["accepted"] as? Bool) == false
    }

    static func decodeError(data: Data, status: Int) -> ClikgateError {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let e = EngageJSON(root?["error"]), let code = e.str("code") {
            return ClikgateError(code: code, message: e.str("message") ?? code, status: status, param: e.str("param"),
                                 requestId: e.str("request_id"), feature: e.str("feature"),
                                 offlineTouchId: e.str("offline_touch_id"))
        }
        let code: String
        switch status {
        case 401: code = ClikgateError.invalidSdkKey
        case 422: code = ClikgateError.validationError
        case 429: code = ClikgateError.rateLimited
        case 500...: code = ClikgateError.serverError
        default: code = "http_\(status)"
        }
        return ClikgateError(code: code, message: "HTTP \(status)", status: status)
    }
}

/// Minimal typed reads of a JSON object (unknown fields are ignored).
struct EngageJSON: @unchecked Sendable {
    let o: [String: Any]

    init?(_ any: Any?) {
        guard let o = any as? [String: Any] else { return nil }
        self.o = o
    }

    init(object: [String: Any]) { o = object }

    func str(_ k: String) -> String? { o[k] as? String }
    func int(_ k: String) -> Int? {
        guard let n = o[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.intValue
    }
    func bool(_ k: String) -> Bool? {
        guard let n = o[k] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
    func obj(_ k: String) -> EngageJSON? { EngageJSON(o[k]) }
    func objects(_ k: String) -> [EngageJSON] {
        var out: [EngageJSON] = []
        for e in o[k] as? [Any] ?? [] { if let j = EngageJSON(e) { out.append(j) } }
        return out
    }
}

enum EngageDates {
    static func parse(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
