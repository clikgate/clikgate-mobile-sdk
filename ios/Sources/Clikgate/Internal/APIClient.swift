import Foundation

enum RetryMode: Sendable, Equatable {
    /// Single attempt.
    case none
    /// Up to `n` attempts in total.
    case attempts(Int)
    /// Until success or a non-retryable error (used for `/install` and `/opt-out`).
    case forever
}

struct WrapperInfo: Sendable, Equatable {
    var name: String
    var version: String
}

/// HTTP layer: headers, JSON, error decoding and the contract's retry policy.
struct APIClient: Sendable {
    let baseURL: URL
    let sdkKey: String
    let transport: HTTPTransport
    let clock: ClikgateClock
    let jitter: @Sendable () -> Double
    let wrapper: WrapperInfo?
    let logger: ClikgateLogger

    var sdkVersionHeader: String {
        if let w = wrapper { return "\(w.name)/\(w.version)" }
        return "ios/\(Clikgate.sdkVersion)"
    }

    /// `min(60 s, 1 s * 2^attempt)` with ±20 % jitter.
    func backoff(attempt: Int) -> Double {
        let base = min(60.0, pow(2.0, Double(min(attempt, 16))))
        return max(0, base * (1 + 0.2 * jitter()))
    }

    func makeRequest(method: String, path: String, query: [URLQueryItem] = [], body: Data?,
                     installationId: String?, identityToken: String?, idempotencyKey: String?) -> URLRequest {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(sdkKey, forHTTPHeaderField: "Clikgate-SDK-Key")
        req.setValue(sdkVersionHeader, forHTTPHeaderField: "Clikgate-SDK-Version")
        if wrapper != nil { req.setValue("ios/\(Clikgate.sdkVersion)", forHTTPHeaderField: "Clikgate-SDK-Native-Version") }
        if let id = installationId { req.setValue(id, forHTTPHeaderField: "Clikgate-Installation-Id") }
        if let t = identityToken { req.setValue(t, forHTTPHeaderField: "Clikgate-Identity-Token") }
        if let k = idempotencyKey { req.setValue(k, forHTTPHeaderField: "Idempotency-Key") }
        if let body = body {
            req.httpBody = body
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    /// One HTTP exchange; maps non-2xx to `ClikgateError` and transport failures to `network_error`.
    func perform(_ request: URLRequest) async -> Result<Data, CallFailure> {
        do {
            let (data, http) = try await transport.send(request)
            if (200..<300).contains(http.statusCode) { return .success(data) }
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
            return .failure(CallFailure(error: Self.decodeError(data: data, status: http.statusCode), retryAfter: retryAfter))
        } catch {
            let timedOut = (error as? URLError)?.code == .timedOut
            return .failure(CallFailure(error: ClikgateError(code: timedOut ? ClikgateError.timeout : ClikgateError.networkError,
                                                            message: "Network request failed"),
                                        retryAfter: nil, isNetwork: true))
        }
    }

    static func decodeError(data: Data, status: Int) -> ClikgateError {
        if let e = JSON.object(data)?.obj("error"), let code = e.str("code") {
            // `/codes/redeem` referral errors: the touch was recorded although the referral failed.
            return ClikgateError(code: code, message: e.str("message") ?? code, status: status,
                                 param: e.str("param"), requestId: e.str("request_id"),
                                 feature: e.str("feature"), offlineTouchId: e.str("offline_touch_id"))
        }
        // A goal refusal answered as a result body (`{status: "refused", reason: ...}`): the reason is the code.
        if let j = JSON.object(data), j.str("status") == "refused", let reason = j.str("reason") {
            return ClikgateError(code: reason, message: "HTTP \(status)", status: status)
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

    static func isRetryable(_ f: CallFailure) -> Bool {
        if f.isNetwork { return true }
        guard let s = f.error.status else { return false }
        if s == 408 || s == 429 || s >= 500 { return true }
        if s == 409 && f.error.code == ClikgateError.installInProgress { return true }
        return false
    }

    /// Sends with the retry policy. `beforeAttempt` lets the core re-check gates (opt-out, kill switch)
    /// and rebuild headers between attempts; returning nil aborts with that error.
    ///
    /// `maxRetryDelay`: interactive calls don't wait longer than this for a retry (e.g. a long
    /// `Retry-After`); the failure is returned instead.
    func send(_ build: @Sendable () async -> Result<URLRequest, ClikgateError>, retry: RetryMode,
              maxRetryDelay: Double = .infinity) async -> Result<Data, CallFailure> {
        var attempt = 0
        while true {
            if Task.isCancelled {
                return .failure(CallFailure(error: ClikgateError(code: "cancelled", message: "Cancelled"), retryAfter: nil))
            }
            let request: URLRequest
            switch await build() {
            case .success(let r): request = r
            case .failure(let e): return .failure(CallFailure(error: e, retryAfter: nil))
            }
            let result = await perform(request)
            guard case .failure(let failure) = result else { return result }
            attempt += 1
            let canRetry: Bool
            switch retry {
            case .none: canRetry = false
            case .attempts(let n): canRetry = attempt < n
            case .forever: canRetry = true
            }
            guard canRetry, Self.isRetryable(failure) else { return result }
            let wait = failure.retryAfter.map { max($0, 0) } ?? backoff(attempt: attempt - 1)
            let retrying = wait <= maxRetryDelay
            logger.debug("\(request.url?.path ?? "") failed (\(failure.error.code)); " + (retrying ? "retrying in \(Int(wait.rounded(.up))) s" : "not retrying"))
            guard retrying else { return result }
            await clock.sleep(seconds: wait)
        }
    }
}

struct CallFailure: Error, Sendable {
    var error: ClikgateError
    var retryAfter: Double?
    var isNetwork = false
}
