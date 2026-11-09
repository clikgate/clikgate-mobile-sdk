import Foundation

/// Delivers deep links on the main thread; buffers the latest 10 until a handler is registered.
final class DeepLinkDispatcher: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (ClikgateDeepLinkResult) -> Void

    static let bufferLimit = 10
    private let lock = NSLock()
    private var handler: Handler?
    private var buffer: [ClikgateDeepLinkResult] = []

    func setHandler(_ h: Handler?) {
        lock.lock()
        handler = h
        let pending = h == nil ? [] : buffer
        if h != nil { buffer = [] }
        lock.unlock()
        guard let h = h, !pending.isEmpty else { return }
        DispatchQueue.main.async {
            for r in pending { h(r) }
        }
    }

    func deliver(_ r: ClikgateDeepLinkResult) {
        lock.lock()
        guard let h = handler else {
            buffer.append(r)
            if buffer.count > Self.bufferLimit { buffer.removeFirst(buffer.count - Self.bufferLimit) }
            lock.unlock()
            return
        }
        lock.unlock()
        DispatchQueue.main.async { h(r) }
    }

    var bufferedCount: Int { lock.lock(); defer { lock.unlock() }; return buffer.count }

    private var passwordUrl: String?
    private var passwordAt = Date.distantPast

    /// Not async, which keeps `resolve` small. With `password` (`password_required`, the link's
    /// `web_url`): the password page in the system browser, at most once per URL per 30 s (no loop). Otherwise, with
    /// `fallback`, another organisation's shared-domain link in the in-app browser (main queue), posting
    /// `Clikgate.browserHandoffNotification`.
    func handOff(_ url: URL, _ browser: BrowserPresenting, password: String? = nil, fallback: Bool = true) {
        var target = url
        if let w = password {
            let now = Date()
            lock.lock()
            let again = w == passwordUrl && now.timeIntervalSince(passwordAt) < 30
            if !again { passwordUrl = w; passwordAt = now }
            lock.unlock()
            if again { return }
            target = URL(string: w) ?? url
        } else if !fallback || SharedDomains.host(url) == nil { return }
        DispatchQueue.main.async {
            if password != nil { browser.openExternal(target) }
            else if browser.open(target) { NotificationCenter.default.post(name: Clikgate.browserHandoffNotification, object: target) }
        }
    }
}

/// Link domains readable synchronously by `handle(url:)` (options ∪ cached config).
final class LinkDomainsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var optionDomains: [String]
    private var configDomains: [String] = []
    private var warned: Set<String> = []

    init(optionDomains: [String]) {
        self.optionDomains = optionDomains.map(LinkMatcher.normalize).filter { !$0.isEmpty }
    }

    /// Sets the server's `link_domains` and returns those not in `ClikgateOptions.linkDomains` that
    /// weren't reported before (the caller warns about each once per launch).
    @discardableResult
    func setConfigDomains(_ d: [String]) -> [String] {
        lock.lock(); defer { lock.unlock() }
        configDomains = d.map(LinkMatcher.normalize).filter { !$0.isEmpty }
        let missing = configDomains.filter { !optionDomains.contains($0) && !warned.contains($0) }
        warned.formUnion(missing)
        return missing
    }

    static func missingWarning(_ domain: String) -> String {
        "Link domain \(domain) is listed by Clikgate but not in ClikgateOptions.linkDomains. iOS opens the app only for "
            + "domains in the Associated Domains entitlement: add applinks:\(domain) (and add it to linkDomains)."
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(Set(optionDomains + configDomains))
    }
}
