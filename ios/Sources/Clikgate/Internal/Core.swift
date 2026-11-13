import Foundation
import CryptoKit

/// All SDK state and network work. Public methods on `Clikgate` forward here.
actor ClikgateCore {
    let options: ClikgateOptions
    let deps: ClikgateDependencies
    let logger: ClikgateLogger
    let api: APIClient
    let dispatcher: DeepLinkDispatcher
    let linkDomains: LinkDomainsBox

    private let stateStore: JSONFile
    private(set) var state: PersistedState
    private let queue: EventQueue
    private(set) var config = RemoteConfig()
    /// v3 feature switches (`Clikgate.isFeatureEnabled`), readable from any thread. Loaded
    /// synchronously from the cached config here, so a relaunch knows them before any fetch.
    nonisolated let features: FeatureSwitches
    /// Consent and sales metadata for the facade's synchronous getters.
    nonisolated let snapshot: SyncSnapshot

    // Runtime gates (not persisted: re-evaluated on every launch).
    private var sdkKeyInvalid = false
    private var disabledUntil: Date?
    private var serverOptedOut = false

    private var started = false
    private var installRunning = false
    private var installRecoveryAttempted = false
    private var flushing = false
    private var privateModeWarned = false
    private(set) var needsGrowthWarned = false
    private var optOutSending = false
    private var pendingColdOpen = false
    private var foregroundTimer: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<ClikgateAttribution, Never>] = [:]
    private var deliveredDeferredLink = false
    // Consent, Firebase and measurement
    private var firebaseOptions: ClikgateFirebaseForwardingOptions?
    private var odmEnabled = false
    private var versionPolicyLogged = false
    private var autoPushDone = false
    /// Test SDK key (`cg_sdk_test_`): goal results get one clear log line; handled deep links are reported.
    let testMode: Bool
    /// `goal()` completions by queue id, settled when Clikgate answers (in memory only).

    init(sdkKey: String, options: ClikgateOptions, deps: ClikgateDependencies, logger: ClikgateLogger,
         dispatcher: DeepLinkDispatcher, linkDomains: LinkDomainsBox, wrapper: WrapperInfo?,
         snapshot: SyncSnapshot = SyncSnapshot()) {
        self.options = options
        self.deps = deps
        self.logger = logger
        self.dispatcher = dispatcher
        self.linkDomains = linkDomains
        testMode = sdkKey.hasPrefix("cg_sdk_test_")
        api = APIClient(baseURL: options.apiBaseUrl, sdkKey: sdkKey, transport: deps.transport, clock: deps.clock,
                        jitter: deps.jitter, wrapper: wrapper, logger: logger)
        stateStore = JSONFile(directory: deps.storageDirectory, fileName: "state.json")
        state = (stateStore.load() as? JSONObject).map(PersistedState.init(json:)) ?? PersistedState()
        queue = EventQueue(directory: deps.storageDirectory)
        features = FeatureSwitches(switches: state.config?.switches)
        self.snapshot = snapshot
        if let cached = state.config {
            config = cached
            for d in linkDomains.setConfigDomains(cached.linkDomains) { logger.warning(LinkDomainsBox.missingWarning(d)) }
            queue.maxEvents = cached.batching.maxQueueEvents
            queue.maxBytes = cached.batching.maxQueueBytes
        }
    }

    // MARK: - Lifecycle

    /// Steps 1–6 of the lifecycle.
    func start(launchedInBackground: Bool = false, startTimers: Bool = true) async {
        guard !started else { return }
        started = true
        ensureInstallationId()

        if !state.trackingEnabled {
            logger.info("Tracking disabled; only opt-out calls are sent")
            if !state.installDone {
                await runInstall()            // every consent purpose denied
            } else if state.optOutPending != nil {
                await sendOptOut()
            }
            return
        }
        if state.optOutPending != nil { await sendOptOut() }

        await refreshConfig()
        applyVersionPolicy()
        updateSnapshot()

        guard await consentAllowsProgress() else {
            if startTimers && !launchedInBackground { startForegroundTimer() }
            return
        }
        if !state.installDone {
            await runInstall()
        } else if launchedInBackground {
            pendingColdOpen = true
        } else {
            await sendOpen(coldStart: true)
        }
        await afterConsentGranted()
        await registerForPushIfNeeded()
        await reattestIfDue()
        await flush()
        if startTimers && !launchedInBackground { startForegroundTimer() }
    }

    private func ensureInstallationId() {
        if let id = state.installationId {
            if deps.keychain.readInstallationId() != id { deps.keychain.writeInstallationId(id) }
            return
        }
        let previous = deps.keychain.readInstallationId()
        let newId = deps.uuid()
        state.installationId = newId
        if state.firstLaunchAt == nil { state.firstLaunchAt = deps.clock.now() }
        if let previous = previous, previous != newId {
            state.keychainPreviousInstallationId = previous
            logger.info("Reinstall detected (Keychain installation id present)")
        }
        deps.keychain.writeInstallationId(newId)
        save()
    }

    func appDidEnterBackground() async {
        state.lastBackgroundAt = deps.clock.now()
        save()
        foregroundTimer?.cancel()
        foregroundTimer = nil
    }

    func appWillEnterForeground(startTimers: Bool = true) async {
        guard started, isActive else { return }
        guard gate == .allowed else {
            expireConsentBuffer()
            state.lastBackgroundAt = nil
            save()
            return
        }
        let now = deps.clock.now()
        if pendingColdOpen {
            pendingColdOpen = false
            await sendOpen(coldStart: true)
        } else if let bg = state.lastBackgroundAt,
                  now.timeIntervalSince(bg) >= Double(config.sessionTimeoutMinutes) * 60 {
            if state.config == nil || isConfigStale { await refreshConfig() }
            await sendOpen(coldStart: false)
        }
        state.lastBackgroundAt = nil
        save()
        await flush()
        await registerForPushIfNeeded()
        if startTimers { startForegroundTimer() }
    }

    private func startForegroundTimer() {
        foregroundTimer?.cancel()
        let interval = Double(config.batching.flushIntervalSeconds)
        let clock = deps.clock
        foregroundTimer = Task { [weak self] in
            while !Task.isCancelled {
                await clock.sleep(seconds: interval)
                if Task.isCancelled { break }
                await self?.flushIfNeeded()
            }
        }
    }

    private func flushIfNeeded() async {
        if queue.count > 0 || state.identifyPending { await flush() }
    }

    // MARK: - Gates

    private var isActive: Bool { state.trackingEnabled && !serverOptedOut }

    private func gateError() -> ClikgateError? {
        if sdkKeyInvalid { return ClikgateError(code: ClikgateError.invalidSdkKey, message: "The SDK key was rejected; calls stop until the next launch.") }
        if let until = disabledUntil, deps.clock.now() < until {
            return ClikgateError(code: ClikgateError.sdkDisabled, message: "The Clikgate SDK is disabled for this app; backing off.")
        }
        return nil
    }

    private func activeGateError() -> ClikgateError? {
        if !isActive { return ClikgateError(code: ClikgateError.optedOut, message: "Tracking is disabled for this installation.") }
        return gateError()
    }

    /// Applies the contract's side effects for special error codes.
    private func noteFailure(_ e: ClikgateError) {
        switch e.code {
        case ClikgateError.invalidSdkKey:
            sdkKeyInvalid = true
            logger.errorOnce("invalid_sdk_key", "Invalid SDK key: Clikgate calls stop until the next app launch.")
        case ClikgateError.sdkDisabled:
            disabledUntil = deps.clock.now().addingTimeInterval(3600)
            logger.warning("Clikgate SDK disabled for this app; backing off for 1 hour.")
        case ClikgateError.optedOut where e.status == 403:
            serverOptedOut = true
            if state.trackingEnabled {
                state.trackingEnabled = false
                refuseQueued(ClikgateError.optedOut)
                queue.clear()
                save()
            }
            logger.info("Installation is opted out server-side.")
        case ClikgateError.validationError:
            logger.error("Request rejected as invalid: \(e.message)")
        default:
            break
        }
    }

    // MARK: - HTTP helpers

    private func encode(_ body: JSONObject) -> Data? { JSON.data(body) }

    private func request(_ method: String, _ path: String, body: Data?, query: [URLQueryItem] = [],
                         identity: Bool = false, idempotencyKey: String? = nil, allowWhenOptedOut: Bool = false) -> Result<URLRequest, ClikgateError> {
        if let e = allowWhenOptedOut ? gateError() : activeGateError() { return .failure(e) }
        let name = SDKCall.name(path: path)
        if let e = callGateError(name) { return .failure(e) }
        // No installation id while buffering / denied, nor on a /config before the SDK knows whether
        // consent is required (first launch) unless attribution was granted (same as Android).
        let anonymous = name == "install_ping" ||
            (name == "config" && (gate != .allowed || (consentRequired == nil && state.consent.attribution != .granted)))
        return .success(api.makeRequest(method: method, path: path, query: query, body: body,
                                        installationId: anonymous ? nil : state.installationId,
                                        identityToken: identity ? state.identityToken : nil,
                                        idempotencyKey: idempotencyKey))
    }

    private func call(_ method: String, _ path: String, body: Data?, query: [URLQueryItem] = [], identity: Bool = false,
                      idempotencyKey: String? = nil, allowWhenOptedOut: Bool = false, retry: RetryMode,
                      maxRetryDelay: Double = .infinity) async -> Result<Data, CallFailure> {
        let result = await api.send({ [self] in
            await self.request(method, path, body: body, query: query, identity: identity,
                               idempotencyKey: idempotencyKey, allowWhenOptedOut: allowWhenOptedOut)
        }, retry: retry, maxRetryDelay: maxRetryDelay)
        if case .failure(let f) = result { noteFailure(f.error) }
        return result
    }

    private func parse(_ data: Data) -> JSONObject? {
        let o = JSON.object(data)
        if o == nil { logger.error("Unexpected (non-JSON) response body") }
        return o
    }

    private func save() { stateStore.save(state.json) }

    // MARK: - Config

    private var configFetching = false

    private var isConfigStale: Bool {
        guard let at = state.configFetchedAt else { return true }
        let age = deps.clock.now().timeIntervalSince(at)
        return age >= 3600 || age < 0
    }

    func refreshConfig(force: Bool = false) async {
        if !force && state.config != nil && !isConfigStale { return }
        guard !configFetching else { return }
        configFetching = true
        defer { configFetching = false }
        let hint = state.consent.region.map { [URLQueryItem(name: "region_hint", value: $0)] } ?? []
        let result = await call("GET", "v1/sdk/config", body: nil, query: hint, retry: .attempts(force ? 1 : 2))
        if case .success(let data) = result, let j = parse(data) {
            let c = RemoteConfig(json: j)
            applyConfig(c)
            features.apply(c.switches, clearServerDisabled: true)
            state.config = c
            state.configFetchedAt = deps.clock.now()
            save()
            updateSnapshot()
        } else if state.config == nil {
            logger.warning("No Clikgate config available; using defaults (all features off)")
        }
    }

    private func applyConfig(_ c: RemoteConfig) {
        config = c
        if c.privateMode { warnPrivateMode() }
        for d in linkDomains.setConfigDomains(c.linkDomains) { logger.warning(LinkDomainsBox.missingWarning(d)) }
        queue.maxEvents = c.batching.maxQueueEvents
        queue.maxBytes = c.batching.maxQueueBytes
        queue.trim()
        if let env = c.environment, env != options.environment.rawValue {
            logger.warning("ClikgateOptions.environment is \(options.environment.rawValue) but the SDK key belongs to a \(env) app")
        }
    }

    // MARK: - Install

    private func collectFirstLaunchSignals() async {
        guard !state.firstLaunchSignalsCollected else { return }
        state.firstLaunchSignalsCollected = true   // never read the pasteboard again, even if we crash
        save()
        let (token, outcome) = await readPasteboardIfAllowed()
        if let token { state.pasteboardToken = token }
        state.pasteboardOutcome = outcome
        save()
    }

    /// The token (if any) and the `pasteboard_outcome` (nil when the paste flow doesn't run).
    private func readPasteboardIfAllowed() async -> (String?, String?) {
        guard options.pasteboardMode != .off, config.features.pasteboardMatching == "on_interstitial_tap",
              !isBlocked, gate != .denied else { return (nil, nil) }
        guard options.pasteboardMode == .automatic else { return (nil, "paste_control") }
        if let likely = await deps.pasteboard.probablyHasWebURL() {
            guard likely else { return (nil, "no_link") }
        } else {
            guard await deps.pasteboard.hasStrings() else { return (nil, "no_link") }
        }
        guard let text = await deps.pasteboard.readString() else { return (nil, "denied") }
        let token = PasteboardToken.extract(from: text)
        logger.debug(token == nil ? "No Clikgate token on the pasteboard" : "Found a Clikgate pasteboard token")
        return (token, token == nil ? "no_token" : "token_found")
    }

    private func waitForATTIfNeeded() async {
        guard options.waitForATT else { return }
        let deadline = deps.clock.now().addingTimeInterval(30)
        while deps.tracking.isNotDetermined() && deps.clock.now() < deadline {
            await deps.clock.sleep(seconds: 0.5)
        }
    }

    private struct SentInstall: Sendable {
        var pushHash: String?
        var launchUrl: String?
        var pasteboardToken: String?
        var attested: Bool
        /// The opted-out first install: its consent said every purpose denied, not the app's values.
        var optedOut = false
    }

    private func buildInstallRequest(device: DeviceInfo, attestation: AttestationPayload?,
                                     extras: InstallExtras = InstallExtras()) -> (InstallRequest, SentInstall) {
        let tracking = state.trackingEnabled
        if tracking && isBlocked {
            // Blocked SDK version: required fields + consent + launch URL only.
            var req = InstallRequest(
                installationId: state.installationId ?? deps.uuid(), keychainPreviousInstallationId: nil,
                appVersion: device.appVersion, sdkVersion: Clikgate.sdkVersion, osVersion: nil, deviceModel: nil,
                locale: nil, timezone: nil, launchUrl: state.launchUrl, pasteboardToken: nil, push: nil,
                attestation: nil, appleSearchAdsToken: nil, trackingAllowed: true, isEmulator: nil)
            req.consent = state.consent
            return (req, SentInstall(pushHash: nil, launchUrl: req.launchUrl, pasteboardToken: nil, attested: false))
        }
        var push: PushPayload?
        var pushHash: String?
        if tracking, let p = currentPushPayload() { push = p; pushHash = PushTokens.hash(provider: p.provider, token: p.token) }
        let restricted = config.features.restrictedMode
        var req = InstallRequest(
            installationId: state.installationId ?? deps.uuid(),
            keychainPreviousInstallationId: state.keychainPreviousInstallationId,
            appVersion: device.appVersion,
            sdkVersion: Clikgate.sdkVersion,
            osVersion: device.osVersion,
            deviceModel: (restricted || !tracking) ? nil : device.deviceModel,
            locale: tracking ? device.locale : nil,
            timezone: tracking ? device.timezone : nil,
            launchUrl: tracking ? state.launchUrl : nil,
            pasteboardToken: tracking ? state.pasteboardToken : nil,
            push: push,
            attestation: tracking ? attestation : nil,
            appleSearchAdsToken: tracking && extras.sendsSearchAds ? searchAdsTokenForInstall() : nil,
            trackingAllowed: tracking,
            isEmulator: device.isSimulator
        )
        req.consent = state.consent
        if tracking {
            // A Paste button token that arrives before the first install is sent as found too.
            req.pasteboardOutcome = state.pasteboardOutcome.map { state.pasteboardToken == nil ? $0 : "token_found" }
            req.googleClickIds = GoogleClickIds.parse(state.launchUrl.flatMap(URL.init(string:)))
            req.appInstanceId = extras.appInstanceId
            req.deviceCheckToken = extras.deviceCheckToken
            req.idfv = extras.idfv
            req.odmInfo = extras.odmInfo
            req.odmSdkVersion = extras.odmSdkVersion
        }
        return (req, SentInstall(pushHash: pushHash, launchUrl: req.launchUrl, pasteboardToken: req.pasteboardToken,
                                 attested: req.attestation != nil, optedOut: !tracking))
    }

    func runInstall() async {
        guard !installRunning, !state.installDone else { return }
        let tracking = state.trackingEnabled
        if tracking && gate != .allowed { return }
        installRunning = true
        defer { installRunning = false }

        var collected = InstallExtras()
        if tracking {
            await collectFirstLaunchSignals()
            await waitForATTIfNeeded()
            collected = await collectInstallExtras()
        }
        let extras = collected
        let attestation = tracking && !isBlocked && identityAllowed ? await attestationForInstall() : nil
        let attestedAt = deps.clock.now()
        let device = await deps.device.collect()

        lastSentInstall = nil
        let result = await api.send({ [self] in
            await self.installAttempt(device: device, attestation: attestation, attestedAt: attestedAt, extras: extras)
        }, retry: .forever)
        switch result {
        case .failure(let f):
            noteFailure(f.error)
            logger.warning("/install failed (\(f.error.code)); it will be retried on the next launch")
            resolveWaiters(with: state.attribution ?? ClikgateAttribution(status: .pending))
        case .success(let data):
            guard let response = InstallResponse(json: parse(data)) else { return }
            let s = lastSentInstall ?? SentInstall(pushHash: nil, launchUrl: nil, pasteboardToken: nil, attested: false)
            if extras.odmInfo != nil || extras.odmAttempted { state.odmCollected = true }
            if let id = extras.appInstanceId { state.lastAppInstanceIdSent = id }
            await handleInstallResponse(response, sent: s)
        }
    }

    private var lastSentInstall: SentInstall?
    /// AdServices token, in memory only: fetched when /install is actually sent (also after consent buffering),
    /// again after 24 hours (Apple's validity), dropped once sent. Never written to disk.
    private var adServicesToken: (token: String, at: Date)?

    private func searchAdsTokenForInstall() -> String? {
        guard config.features.appleSearchAds, !isBlocked, gate == .allowed, allowed(state.consent.attribution) else {
            adServicesToken = nil
            return nil
        }
        let now = deps.clock.now()
        if let s = adServicesToken, now.timeIntervalSince(s.at) < 86_400 { return s.token }
        adServicesToken = deps.searchAds.attributionToken().map { (token: $0, at: now) }
        return adServicesToken?.token
    }

    private func installAttempt(device: DeviceInfo, attestation: AttestationPayload?, attestedAt: Date,
                                extras: InstallExtras) -> Result<URLRequest, ClikgateError> {
        if let e = gateError() { return .failure(e) }
        if state.trackingEnabled, let e = callGateError("install") { return .failure(e) }
        // Challenges are single-use and expire after 5 minutes: later retries go without the
        // attestation, and reattestIfDue() attests through /attest once the install exists.
        let fresh = deps.clock.now().timeIntervalSince(attestedAt) < 270
        var x = extras
        x.sendsSearchAds = true
        let (body, s) = buildInstallRequest(device: device, attestation: fresh ? attestation : nil, extras: x)
        lastSentInstall = s
        guard let data = encode(body.json) else {
            return .failure(ClikgateError(code: ClikgateError.invalidArgument, message: "Could not encode install request"))
        }
        return .success(api.makeRequest(method: "POST", path: "v1/sdk/install", body: data, installationId: state.installationId,
                                        identityToken: nil, idempotencyKey: nil))
    }

    private func handleInstallResponse(_ r: InstallResponse, sent: SentInstall) async {
        state.installId = r.installId
        var attribution = r.attribution ?? ClikgateAttribution(status: .organic)
        attribution.installId = r.installId
        state.attribution = attribution
        state.keychainPreviousInstallationId = nil
        if sent.pasteboardToken != nil { state.pasteboardToken = nil }
        state.pasteboardOutcome = nil
        adServicesToken = nil
        if let h = sent.pushHash { state.lastPushHash = h }
        if sent.attested { state.attestKeyAttested = true; state.lastAttestedAt = deps.clock.now() }
        let launchUrlConsumed = sent.launchUrl != nil
        if launchUrlConsumed { state.launchUrl = nil }
        // The app's own consent values go through /consent once tracking is back on.
        if sent.optedOut && !state.consent.isAllDenied { state.consentRecordPending = true }
        state.optOutPending = nil
        state.lastOpenAt = deps.clock.now()
        save()

        let deliveredLocally = state.launchUrlDeliveredLocally
        state.launchUrlDeliveredLocally = false
        save()
        updateSnapshot()
        if state.trackingEnabled {
            if let dl = r.deepLink {
                if deliveredLocally && dl.isDeferred != true {
                    deliveredDeferredLink = true   // the app already got this link locally (consent buffering)
                } else {
                    deliverDeferred(dl, attribution: attribution, r)
                }
            } else if launchUrlConsumed, !deliveredLocally, let url = sent.launchUrl.flatMap(URL.init(string:)) {
                // One tap is one click. /install already recorded a matched launch URL's click, so
                // /resolve attaches to it by `click_id`, never the URL (which would record a second click).
                if !r.launchMatched { await resolve(url: url) }
                else if let c = attribution.clickId { await resolve(url: url, clickId: c) }
                else { dispatcher.deliver(Self.localDeepLink(url)) }
            }
        }
        if attribution.status != .pending {
            resolveWaiters(with: attribution)
            logFirebaseAttributionIfNeeded()
        }

        if let pending = state.launchUrl, let url = URL(string: pending) {
            // A URL arrived while /install was in flight.
            state.launchUrl = nil
            save()
            await resolve(url: url)
        }

        if let delay = r.retryAfterMs, attribution.status == .pending, state.trackingEnabled {
            await pollPendingAttribution(initialDelayMs: delay)
        }
        if state.trackingEnabled { await flush() }
    }

    private func deliverDeferred(_ dl: WireDeepLink, attribution: ClikgateAttribution, _ r: InstallResponse) {
        guard !deliveredDeferredLink else { return }
        deliveredDeferredLink = true
        let url = dl.url.flatMap(URL.init(string:))
        dispatcher.deliver(ClikgateDeepLinkResult(
            url: url, path: dl.path, dataJSON: dl.data,
            isDeferred: dl.isDeferred ?? true, clickId: attribution.clickId, matchType: attribution.matchType,
            link: attribution.link, referral: r.referral))
        reportHandled(dl.path ?? url?.path, deferred: dl.isDeferred ?? true, debugView: r.debugView)
    }

    /// `deeplink_handled` (the live check) with the delivered link's path (IDs → `:id`), only with a test key,
    /// while the answer says the debug view is open, or (live mode too) for an App banner tap that
    /// measures the right screen (sent with its `click_id`). Never queued, counted or a goal; one retry, then dropped.
    private func reportHandled(_ path: String?, deferred: Bool, debugView: Bool, bannerClickId: String? = nil) {
        guard testMode || debugView || bannerClickId != nil else { return }
        var b: [String: Any] = ["path": DeepLinkPath.clean(path ?? ""), "is_deferred": deferred]
        if let c = bannerClickId { b["click_id"] = c }
        let body = encode(b)
        Task { _ = await call("POST", "v1/sdk/deeplink-handled", body: body, retry: .attempts(2)) }
    }

    /// `retry_after_ms`: call `/install` again (idempotent) at most 3 times.
    private func pollPendingAttribution(initialDelayMs: Int) async {
        var delayMs = initialDelayMs
        for _ in 0..<3 {
            await deps.clock.sleep(seconds: Double(max(delayMs, 0)) / 1000)
            guard state.trackingEnabled else { return }
            let device = await deps.device.collect()
            let (body, _) = buildInstallRequest(device: device, attestation: nil)
            let result = await call("POST", "v1/sdk/install", body: encode(body.json), retry: .attempts(3))
            guard case .success(let data) = result, let r = InstallResponse(json: parse(data)) else { continue }
            var attribution = r.attribution ?? ClikgateAttribution(status: .organic)
            attribution.installId = r.installId
            state.attribution = attribution
            save()
            updateSnapshot()
            if let dl = r.deepLink { deliverDeferred(dl, attribution: attribution, r) }
            if attribution.status != .pending || r.retryAfterMs == nil {
                resolveWaiters(with: attribution)
                logFirebaseAttributionIfNeeded()
                return
            }
            delayMs = r.retryAfterMs ?? delayMs
        }
        resolveWaiters(with: state.attribution ?? ClikgateAttribution(status: .pending))
    }

    /// `.pasteControlOnly`: the app's ClikgatePasteControl delivered pasteboard text.
    func applyPastedText(_ text: String?) async -> Bool {
        guard let token = PasteboardToken.extract(from: text) else { return false }
        guard isActive, !isBlocked, gate != .denied else { return false }
        if !state.installDone || gate == .pending {
            state.pasteboardToken = token
            save()
            if started { await runInstall() }
            return true
        }
        let device = await deps.device.collect()
        var (body, _) = buildInstallRequest(device: device, attestation: nil)
        body.pasteboardToken = token
        body.launchUrl = nil
        let result = await call("POST", "v1/sdk/install", body: encode(body.json), retry: .attempts(3))
        guard case .success(let data) = result, let r = InstallResponse(json: parse(data)) else { return false }
        var attribution = r.attribution ?? ClikgateAttribution(status: .organic)
        attribution.installId = r.installId
        state.attribution = attribution
        save()
        if let dl = r.deepLink { deliverDeferred(dl, attribution: attribution, r) }
        return true
    }

    // MARK: - Attribution

    func attribution(timeout: TimeInterval) async -> ClikgateAttribution {
        if let a = state.attribution, a.status != .pending { return a }
        if !isActive || !started && state.installDone { return state.attribution ?? ClikgateAttribution(status: .pending) }
        let id = UUID()
        let clock = deps.clock
        return await withCheckedContinuation { c in
            waiters[id] = c
            Task { [weak self] in
                await clock.sleep(seconds: timeout)
                await self?.timeoutWaiter(id)
            }
        }
    }

    private func timeoutWaiter(_ id: UUID) {
        guard let c = waiters.removeValue(forKey: id) else { return }
        c.resume(returning: state.attribution ?? ClikgateAttribution(status: .pending, installId: state.installId))
    }

    private func resolveWaiters(with a: ClikgateAttribution) {
        let all = waiters
        waiters = [:]
        for (_, c) in all { c.resume(returning: a) }
    }

    // MARK: - Open / resolve

    func sendOpen(coldStart: Bool) async {
        guard state.installDone, isActive, gate == .allowed else { return }
        let push = isBlocked ? nil : currentPushPayload()
        var b = JSONBuilder()
        b.set("app_version", BundleInfo.appVersion())
        b.set("os_version", ProcessInfoVersion.string)
        b.set("is_cold_start", coldStart)
        b.set("push", push?.json)
        b.set("consent", state.consent.json())
        let clickIds = isBlocked ? nil : state.pendingOpenClickIds
        b.set("google_click_ids", clickIds?.json(source: "deep_link"))
        var instanceId: String?
        if let id = await currentAppInstanceId(wait: false), id != state.lastAppInstanceIdSent { instanceId = id }
        b.set("app_instance_id", instanceId)
        let result = await call("POST", "v1/sdk/open", body: encode(b.object), retry: .attempts(5))
        switch result {
        case .success:
            state.lastOpenAt = deps.clock.now()
            if let p = push { state.lastPushHash = PushTokens.hash(provider: p.provider, token: p.token) }
            if clickIds != nil && state.pendingOpenClickIds == clickIds { state.pendingOpenClickIds = nil }
            if let id = instanceId { state.lastAppInstanceIdSent = id }
            save()
        case .failure(let f):
            await recoverIfInstallationUnknown(f.error)
        }
    }

    private func recoverIfInstallationUnknown(_ e: ClikgateError) async {
        guard e.code == ClikgateError.installationUnknown, !installRecoveryAttempted else { return }
        installRecoveryAttempted = true
        logger.warning("Server doesn't know this installation; re-running /install")
        state.installId = nil
        save()
        await runInstall()
    }

    func resolve(url: URL, clickId: String? = nil, deliver: Bool = true) async {
        guard isActive else { return }
        let g = gate
        if g != .allowed || isBlocked && !callAllowed("resolve") {
            // Consent buffering / denied, or a blocked SDK version: no server call; the app still
            // gets the link (URL, path, query parameters).
            if deliver { dispatcher.deliver(Self.localDeepLink(url)) }
            if g == .pending && !isBlocked {
                if !state.installDone && state.launchUrl == nil {
                    state.launchUrl = url.absoluteString
                    state.launchUrlDeliveredLocally = true
                } else {
                    state.keptUrls.append(url.absoluteString)
                    if state.keptUrls.count > 10 { state.keptUrls.removeFirst(state.keptUrls.count - 10) }
                }
                save()
            } else if !state.installDone && g == .allowed && state.launchUrl == nil {
                state.launchUrl = url.absoluteString   // blocked: still sent as launch_url with /install
                state.launchUrlDeliveredLocally = true
                save()
            }
            return
        }
        if !state.installDone {
            state.launchUrl = url.absoluteString   // sent as launch_url with /install
            save()
            return
        }
        let clickIds = GoogleClickIds.parse(url)
        if let ids = clickIds { state.pendingOpenClickIds = ids; save() }
        var b = JSONBuilder()
        if let c = clickId { b.set("click_id", c) } else { b.set("url", url.absoluteString) }
        b.set("consent", state.consent.json())
        b.set("google_click_ids", clickIds?.json(source: "deep_link"))
        let result = await call("POST", "v1/sdk/resolve", body: encode(b.object), retry: .attempts(3))
        switch result {
        case .success(let data):
            guard let r = ResolveResponse(json: parse(data)) else { return }
            guard r.matched || r.blockMessage != nil else {
                // A password link, or another organisation's shared-domain link.
                if deliver { dispatcher.handOff(url, deps.browser, password: r.webUrl, fallback: options.platformDomainBrowserFallback) }
                return
            }
            if r.clickId != nil || r.link != nil {
                state.lastClickId = r.clickId
                state.lastLinkId = r.link?.id
                save()
                updateSnapshot()
            }
            guard deliver else { return }
            dispatcher.deliver(ClikgateDeepLinkResult(
                url: r.deepLink?.url.flatMap(URL.init(string:)) ?? url, path: r.deepLink?.path,
                dataJSON: r.deepLink?.data ?? [:], isDeferred: r.deepLink?.isDeferred ?? false,
                clickId: r.clickId, matchType: r.blockMessage == nil ? "app_link" : nil, link: r.link, referral: r.referral,
                blockMessage: r.blockMessage))   // blocked: no path, click or link
            if r.blockMessage == nil {
                reportHandled(r.deepLink?.path ?? url.path, deferred: r.deepLink?.isDeferred ?? false, debugView: r.debugView,
                              bannerClickId: r.bannerClickId)
            }
        case .failure(let f):
            logger.warning("/resolve failed: \(f.error.code)")
            await recoverIfInstallationUnknown(f.error)
        }
    }

    // MARK: - Installation ID

    /// This installation's ID for identity Path B (the app sends it to its own server, which
    /// calls `identifyUser({appId, installationId, customerId})`). Nil when tracking is off: opted out, consent denied
    /// or not given yet where it's required, or deep-link-only mode. On a first launch it waits for the first config
    /// answer (at most about 5 s; offline it answers at once) so the consent and attribution switches are known.
    func installationIdForApp() async -> String? {
        ensureInstallationId()
        var waited = 0
        while isActive && state.config == nil && configFetching && waited < 50 {
            await deps.clock.sleep(seconds: 0.1)
            waited += 1
        }
        guard isActive, gate == .allowed, features.isEnabled(ClikgateFeatures.appAttribution) else { return nil }
        return state.installationId
    }

    // MARK: - Goals

    /// Enqueues a validated goal in the queue (limits, consent buffering and retries).
    /// `value` is a validated decimal string; a nil `reference` gets a UUID. `done` gets the result.
    /// Validates first: invalid input (a malformed `provider` key too) is logged and refused.
    func goal(_ key: String, value: String?, currency: String?, reference: String?, provider: String? = nil,
              isFirst: Bool?, label: String? = nil, done: (@Sendable (ClikgateGoalResult) -> Void)? = nil) {
        let p = provider.map { ClikgateProvider.fromString($0)?.rawValue ?? "-" }
        var refusal: String?
        if let e = Goals.validate(key: key, value: value, currency: currency, reference: reference, provider: p) {
            logger.error("goal(\(key)): " + e.message)
            refusal = e.code
        } else if !isActive { refusal = ClikgateError.optedOut } else if gate == .denied { refusal = "consent_denied" }
        else if attributionOff() { refusal = "feature_disabled" }
        if let r = refusal { done?(.refused(r)); return }
        let ref = reference ?? deps.uuid()
        let id = "goal:\(key):\(ref)"
        if queue.events.contains(where: { $0.eventId == id }) {
            done?(ClikgateGoalResult(status: .waiting, reason: "already_queued", goalKind: nil, valueIgnored: false))
            return logger.debug("ignored: already queued")
        }
        let at = ISO8601.format(deps.clock.now())
        var b = JSONBuilder()
        b.set("goal", key); b.set("reference", ref); b.set("value", value.flatMap(Goals.normalize)); b.set("currency", currency)
        b.set("is_first", isFirst)
        b.set("label", checkLabel(label))
        b.set("occurred_at", at)
        b.set("click_id", state.lastClickId ?? (state.attribution?.status == .attributed ? state.attribution?.clickId : nil))
        b.set("provider", p)
        var e = QueuedEvent(eventId: id, name: key, occurredAt: at)
        e.goal = JSONValue.object(from: b.object)
        e.done = done
        if enqueue(e), queue.count >= config.batching.flushAtCount { Task { await flush() } }
    }

    /// Refuses every queued goal (the queue is about to be cleared).
    private func refuseQueued(_ reason: String) {
        for e in queue.events { e.done?(.refused(reason)) }
    }

    /// The `/goals` answer: each item's `results` entry (by index); items without one counted.
    private func settleGoals(_ batch: [QueuedEvent], _ j: JSONObject?) {
        var seen = [Bool](repeating: false, count: batch.count)
        for o in j?.objects("results") ?? [] {
            guard let i = o.int("index"), i >= 0, i < batch.count else { continue }
            let s = o.str("status"), kind: ClikgateGoalKind? = o.str("goal_kind").map { $0 == "payment" ? .payment : .standard }
            let r = ClikgateGoalResult(status: s == "counted" ? .counted : s == "waiting" ? .waiting : s == "received" ? .received : .refused,
                                       reason: o.str("reason"), goalKind: kind, valueIgnored: o.bool("value_ignored") ?? false)
            if testMode && kind == .payment && r.status == .waiting {
                logger.warning(batch[i].name + (r.valueIgnored ? " is a Payment goal: waiting for confirmation; its value was ignored"
                                                               : " is a Payment goal: waiting for confirmation"))
            }
            noteUnsetGoal(batch[i].name, r.reason)
            batch[i].done?(r)
            seen[i] = true
        }
        for (i, e) in batch.enumerated() where !seen[i] {
            e.done?(ClikgateGoalResult(status: .counted, reason: nil, goalKind: nil, valueIgnored: false))
        }
    }

    /// Deep-link-only mode (an app with attribution switched off):
    /// `app_attribution` is off in the cached config, or the server answered `feature_disabled` for
    /// `/goals`. Logs the one-time "attribution is switched off" warning.
    private func attributionOff() -> Bool {
        if features.isEnabled(ClikgateFeatures.appAttribution) { return false }
        warnNeedsGrowth()
        return true
    }

    private func warnNeedsGrowth() {
        if needsGrowthWarned { return }
        needsGrowthWarned = true
        logger.warning("goal() is off: app attribution is switched off, so nothing is sent.")
    }

    /// Appends to the queue; false while buffering for consent (nothing more to do).
    private func enqueue(_ e: QueuedEvent) -> Bool {
        let pending = gate == .pending
        if pending { applyBufferLimits() }
        queue.append(e)
        if pending { expireConsentBuffer() }
        return !pending
    }

    /// The next batch of goals. App events an earlier development build left in the persisted queue are dropped
    /// first, never sent (`goal()` is the only method; there is no events endpoint).
    private func nextBatch() -> [QueuedEvent] {
        let legacy = queue.events.filter { $0.goal == nil }
        if !legacy.isEmpty {
            logger.debug("Dropped \(legacy.count) queued app event(s) from an earlier SDK build")
            queue.remove(ids: Set(legacy.map { $0.eventId }))
        }
        return queue.peek(config.batching.maxBatchSize)
    }

    /// Private mode: one warning per launch, debug builds only.
    private func warnPrivateMode() {
        #if DEBUG
        if !privateModeWarned {
            logger.warning("Private mode: customer IDs aren't sent. goal() works as usual.")
        }
        privateModeWarned = true
        #endif
    }

    var queuedEventCount: Int { queue.count }
    var queuedEvents: [QueuedEvent] { queue.events }

    func flush() async {
        guard !flushing, state.installDone, isActive, gateError() == nil, gate == .allowed else { return }
        flushing = true
        defer { flushing = false }

        await sendConsentIfPending()
        if state.identifyPending && callAllowed("identify") { await sendIdentify() }
        if callAllowed("push_token") { await sendPushTokenIfChanged() }

        while queue.count > 0 {
            if attributionOff() {
                // Deep-link-only mode: what was queued before the config said so is dropped, no network.
                refuseQueued("feature_disabled")
                queue.clear()
                return
            }
            let batch = nextBatch()
            if batch.isEmpty { return }
            if !callAllowed("goals") {
                logger.warning("Goals dropped: this SDK version is blocked for them")
                dropGoals(batch, "sdk_version_blocked")
                continue
            }
            let key = deps.uuid()
            let items = batch.compactMap { $0.goal?.anyDictionary }
            let result = await call("POST", "v1/sdk/goals", body: encode(["goals": items, "consent": state.consent.json()]),
                                    idempotencyKey: key, retry: .attempts(5))
            switch result {
            case .success(let data):
                let j = JSON.object(data)
                if FeatureSwitches.isFeatureDisabledBody(j) {
                    // Attribution is off for this app. Drop the batch, never retry.
                    features.markDisabled(j?.str("feature") ?? ClikgateFeatures.appAttribution, ClikgateFeatures.appAttribution)
                    warnNeedsGrowth()
                    dropGoals(batch, "feature_disabled")
                    Task { await self.refreshConfig(force: true) }
                    continue
                }
                let rejected = j?.objects("rejected") ?? []
                if !rejected.isEmpty { logger.warning("\(rejected.count) item(s) rejected by the server and dropped") }
                queue.remove(ids: Set(batch.map { $0.eventId }))
                settleGoals(batch, j)
            case .failure(let f):
                // Malformed: drop, don't retry. Also on any 422 and on a 404 from a server without /goals.
                let st = f.error.status ?? 0, unknownInstall = f.error.code == ClikgateError.installationUnknown
                let drop = f.error.code == ClikgateError.validationError || st == 422 || st == 404 && !unknownInstall
                if drop { dropGoals(batch, f.error.code) }
                await recoverIfInstallationUnknown(f.error)
                if drop { continue }   // installation_unknown: kept, sent again after the reinstall
                return  // stay queued
            }
        }
    }

    /// Removes `batch` from the queue, refusing its goals with `reason`.
    private func dropGoals(_ batch: [QueuedEvent], _ reason: String) {
        queue.remove(ids: Set(batch.map { $0.eventId }))
        for e in batch {
            noteUnsetGoal(e.name, reason)
            e.done?(.refused(reason))
        }
    }

    /// A refused `unknown_goal` (the organisation accepts only goals it has set up): debug builds only, the name only.
    private func noteUnsetGoal(_ name: String, _ reason: String?) {
        #if DEBUG
        if reason == "unknown_goal" { logger.warning("Goal `\(name)` isn't set up in Clikgate") }
        #endif
    }

    /// Flush inside a background-task window (app moved to background).
    func flushInBackground() {
        let runner = deps.background
        runner.run(name: "Clikgate flush") { [weak self] in await self?.flush() }
    }

    // MARK: - Identify

    /// identifyUser(): customerId "\u{0}" (the default) keeps the stored customer ID; nil clears it. In private mode the
    /// customer ID and token are dropped on the device (the label too unless labels are allowed).
    func identifyUser(label: String?, customerId: String?, identityToken: String?) async {
        let l = checkLabel(label), keep = customerId == "\u{0}"
        let customer = !keep || identityToken != nil
        if customer && config.privateMode { warnPrivateMode() }
        if l == nil && (!customer || config.privateMode) { return }
        if customer && !config.privateMode {
            if !keep { state.customerUserId = customerId }
            state.identityToken = state.customerUserId == nil ? nil : identityToken
        }
        if l != nil { state.pendingLabel = l }
        state.identifyPending = true
        save()
        if state.installDone && isActive && gate == .allowed { await sendIdentify() }
    }

    /// Trimmed, at most 80 characters ("" clears), and only where labels are allowed; else nil (logged).
    func checkLabel(_ label: String?) -> String? {
        guard let l = label else { return nil }   // the server trims
        if l.utf16.count <= 80 && config.allowLabels { return l }
        logger.warning("label not sent (over 80 characters, or labels off in private mode)")
        return nil
    }

    private func sendIdentify() async {
        let label = config.allowLabels ? state.pendingLabel : nil
        var b = JSONBuilder()
        if config.privateMode {   // never a customer ID or token; a label only when allowed
            state.customerUserId = nil
            state.identityToken = nil
            warnPrivateMode()
            if label == nil { state.identifyPending = false; state.pendingLabel = nil; return save() }
        } else {
            b.setOrNull("customer_user_id", state.customerUserId)   // explicit null clears (logout)
        }
        b.set("identity_token", state.identityToken)
        b.set("label", label)
        b.set("consent", state.consent.json())
        let sentUser = state.customerUserId, tokenSent = state.identityToken != nil
        let result = await call("POST", "v1/sdk/identify", body: encode(b.object), retry: .attempts(5))
        switch result {
        case .success(let d):
            let j = JSON.object(d)
            if j?.str("label_ignored") == "plan" { logger.warning("label not stored: labels need Growth") }
            // A bad token answers 200 with `verified: false` + `reason`; no `verified` = older server.
            if tokenSent, j?.bool("verified") == false { logger.warning(Self.tokenNotVerifiedMessage(j?.str("reason"))) }
        case .failure(let f):
            if f.error.status != 422 { return }   // retried later
            logger.error("identifyUser refused: " + f.error.code)   // identity_invalid (older servers); the customer ID is kept
        }
        if state.customerUserId == sentUser { state.identifyPending = false; state.pendingLabel = nil }
        save()
    }

    // MARK: - Push

    private func currentPushPayload() -> PushPayload? {
        guard let token = state.pushToken, let provider = state.pushProvider else { return nil }
        guard PushTokens.hash(provider: provider, token: token) != state.lastPushHash else { return nil }
        return PushPayload(provider: provider, token: token, apnsEnvironment: provider == "apns" ? (state.pushApnsEnvironment ?? "production") : nil)
    }

    func setPushToken(_ token: String, provider: String) async {
        guard !token.isEmpty else { return }
        state.pushToken = token
        state.pushProvider = provider
        state.pushApnsEnvironment = provider == "apns" ? deps.apnsEnvironment() : nil
        save()
        if state.installDone && isActive && gate == .allowed { await sendPushTokenIfChanged() }
    }

    /// `automaticPushToken`: once per launch, when uninstall tracking is on and tracking/consent allow the push
    /// token. The token itself comes back through `setPushToken`, so a manual token is never overwritten.
    func registerForPushIfNeeded() async {
        guard options.automaticPushToken, !autoPushDone, config.features.uninstallTracking, isActive,
              gate == .allowed, callAllowed("push_token") else { return }
        autoPushDone = true
        if state.autoPushRegistered {
            if state.pushToken == nil {
                logger.warning("No push token since the last launch: forward it with setPushToken(deviceToken:) in application(_:didRegisterForRemoteNotificationsWithDeviceToken:) and add the Push Notifications capability")
            }
        } else {
            state.autoPushRegistered = true
            save()
            logger.debug("Registered for remote notifications for uninstall checks; forward the token with setPushToken(deviceToken:)")
        }
        let r = deps.remoteNotifications
        await MainActor.run { r.register() }
    }

    private func sendPushTokenIfChanged() async {
        guard let p = currentPushPayload() else { return }
        var body = p.json
        body["consent"] = state.consent.json()
        let result = await call("POST", "v1/sdk/push-token", body: encode(body), retry: .attempts(5))
        if case .success = result, state.pushToken == p.token, state.pushProvider == p.provider {
            state.lastPushHash = PushTokens.hash(provider: p.provider, token: p.token)
            save()
        }
    }

    // MARK: - Opt-out

    func setTrackingEnabled(_ enabled: Bool) async {
        let wasEnabled = state.trackingEnabled
        guard wasEnabled != enabled || (enabled && serverOptedOut) else { return }
        state.trackingEnabled = enabled
        defer { updateSnapshot() }
        if !enabled {
            refuseQueued(ClikgateError.optedOut)
            queue.clear()
            foregroundTimer?.cancel()
            foregroundTimer = nil
            resolveWaiters(with: state.attribution ?? ClikgateAttribution(status: .pending))
        }
        if state.installDone {
            state.optOutPending = !enabled
            save()
            await sendOptOut()
            if enabled && isActive { await flush(); await registerForPushIfNeeded() }
        } else {
            // Before the first /install: the install itself says it (every consent purpose denied).
            state.optOutPending = nil
            save()
            if started { await runInstall() }
        }
    }

    private func sendOptOut() async {
        guard !optOutSending, state.installDone else { return }
        optOutSending = true
        defer { optOutSending = false }
        while let value = state.optOutPending {
            let result = await call("POST", "v1/sdk/opt-out", body: encode(["opt_out": value]),
                                    allowWhenOptedOut: true, retry: .forever)
            guard case .success = result else { return }   // persisted: retried on next launch
            if state.optOutPending == value { state.optOutPending = nil }
            serverOptedOut = value
            save()
        }
    }

    // MARK: - Attestation

    private var attestationEnabled: Bool {
        options.attestation == .appAttestIfAvailable && config.features.iosAppAttest != "off" && deps.appAttest.isSupported
            && identityAllowed
    }

    static func clientDataHash(nonce: String) -> Data {
        let bytes = Base64URL.decode(nonce) ?? Data(nonce.utf8)
        return Data(SHA256.hash(data: bytes))
    }

    private func fetchChallenge() async -> AttestChallengeResponse? {
        let result = await call("POST", "v1/sdk/attest/challenge", body: Data("{}".utf8), retry: .attempts(3))
        guard case .success(let data) = result else { return nil }
        return AttestChallengeResponse(json: parse(data))
    }

    private func attestedKey(hash: Data) async -> (keyId: String, attestation: Data)? {
        for _ in 0..<2 {
            do {
                let keyId: String
                if let k = state.attestKeyId { keyId = k } else {
                    keyId = try await deps.appAttest.generateKey()
                    state.attestKeyId = keyId
                    state.attestKeyAttested = false
                    save()
                }
                let obj = try await deps.appAttest.attestKey(keyId, clientDataHash: hash)
                return (keyId, obj)
            } catch {
                logger.warning("App Attest attestation failed: \(error.localizedDescription)")
                state.attestKeyId = nil   // invalid key: generate a fresh one once
                save()
            }
        }
        return nil
    }

    func attestationForInstall() async -> AttestationPayload? {
        guard attestationEnabled, let ch = await fetchChallenge() else { return nil }
        guard let (keyId, obj) = await attestedKey(hash: Self.clientDataHash(nonce: ch.nonce)) else { return nil }
        return AttestationPayload(type: "app_attest", token: obj.base64EncodedString(), keyId: keyId, challenge: ch.challenge)
    }

    func reattestIfDue() async {
        guard state.installDone, isActive, gate == .allowed, attestationEnabled else { return }
        if let last = state.lastAttestedAt,
           deps.clock.now().timeIntervalSince(last) < Double(config.reattestationIntervalDays) * 86_400 { return }
        guard let ch = await fetchChallenge() else { return }
        let hash = Self.clientDataHash(nonce: ch.nonce)
        var payload: AttestationPayload?
        if state.attestKeyAttested, let keyId = state.attestKeyId,
           let assertion = try? await deps.appAttest.generateAssertion(keyId, clientDataHash: hash) {
            payload = AttestationPayload(type: "app_attest_assertion", token: assertion.base64EncodedString(), keyId: keyId, challenge: ch.challenge)
        } else if let (keyId, obj) = await attestedKey(hash: hash) {
            payload = AttestationPayload(type: "app_attest", token: obj.base64EncodedString(), keyId: keyId, challenge: ch.challenge)
        }
        guard let p = payload else { return }
        var body = p.json
        body["consent"] = state.consent.json()
        if let t = await deps.deviceCheck.token() { body["device_check_token"] = t }
        let result = await call("POST", "v1/sdk/attest", body: encode(body), retry: .attempts(3))
        if case .success = result {
            state.lastAttestedAt = deps.clock.now()
            if p.type == "app_attest" { state.attestKeyAttested = true }
            save()
        }
    }

    // MARK: - Referrals and other feature calls (v3)

    /// A referral call (feature `referrals`, at most 2 attempts): `applyCode`, `referredBy`.
    func referralCall<T: Sendable>(_ parse: @Sendable (JSONObject?) -> T?, method: String, path: String,
                                   query: [URLQueryItem] = [], body: Data?) async throws -> T {
        try await featureCall(ClikgateFeatures.referrals, parse, method: method, path: path, query: query, body: body,
                              retry: .attempts(2))
    }

    /// Runs a call to an endpoint of `feature` once `/install` succeeded and a pending identify was
    /// sent, with the identity token header. Fails fast with `feature_disabled` (no network) when
    /// the switches say the feature is off, before and after the identify wait, and maps the
    /// server's `feature_disabled` no-op body to the same error (marking the feature off in memory
    /// and refreshing the config in the background).
    func featureCall<T: Sendable>(_ feature: String, _ parse: @Sendable (JSONObject?) -> T?, method: String, path: String,
                                  query: [URLQueryItem] = [], body: Data?, retry: RetryMode,
                                  maxRetryDelay: Double = .infinity) async throws -> T {
        guard features.isEnabled(feature) else { throw ClikgateError.featureDisabledError(feature) }
        if let e = activeGateError() { throw e }
        if let e = callGateError(SDKCall.name(path: path)) { throw e }
        guard state.installDone else {
            throw ClikgateError(code: ClikgateError.installPending, message: "The first /install hasn't completed yet.")
        }
        if state.identifyPending { await sendIdentify() }
        // The config may have been fetched while we waited: check again before the request.
        guard features.isEnabled(feature) else { throw ClikgateError.featureDisabledError(feature) }
        let result = await call(method, path, body: body, query: query, identity: true, retry: retry, maxRetryDelay: maxRetryDelay)
        switch result {
        case .success(let data):
            let j = JSON.object(data)
            if FeatureSwitches.isFeatureDisabledBody(j) {
                let key = j?.str("feature") ?? feature
                logger.info("The '\(key)' feature is switched off for this app (server answered feature_disabled)")
                features.markDisabled(key, feature)
                Task { await self.refreshConfig(force: true) }
                throw ClikgateError.featureDisabledError(key)
            }
            guard let value = parse(j) else {
                throw ClikgateError(code: ClikgateError.serverError, message: "Unexpected response from \(path)")
            }
            return value
        case .failure(let f):
            await recoverIfInstallationUnknown(f.error)
            if f.error.code == "identity_expired" || f.error.code == ClikgateError.identityInvalid {
                logger.warning("\(path): the identity token " + (f.error.code == "identity_expired" ? "has expired" : "did not verify")
                               + " (\(f.error.code)); get a new token from your server and call identifyUser again")
            }
            throw f.error
        }
    }

    /// The identify warning for `verified: false`; names the reason, never the token or customer ID.
    static func tokenNotVerifiedMessage(_ reason: String?) -> String {
        let why: String
        switch reason {
        case "expired": why = "expired"
        case "bad_signature": why = "the signature doesn't match"
        case "secret_rotated": why = "it was signed with a secret that has since been rotated"
        case "no_secret_set": why = "no identity secret is set for this app"
        case "not_yet_valid": why = "its issue time is in the future; check the server clock"
        case nil: why = "no reason given"
        case let r?: why = String(r.filter { $0.isLetter || $0.isNumber || $0 == "_" }.prefix(40))   // a newer reason code
        }
        return "identifyUser: the identity token did not verify (\(why)); the customer ID is kept but not verified"
    }

    // MARK: - Engage features (internal request context)

    /// The context Engage needs for a `/v1/sdk` call, with the same gates the core's feature calls
    /// use: opted out / invalid key / kill switch, `install_pending` before the first `/install`,
    /// and a pending identify is sent first so the server knows the user.
    func requestContext() async throws -> ClikgateRequestContext {
        if let e = activeGateError() { throw e }
        if gate != .allowed { throw Self.consentRequiredError() }
        if isBlocked, let b = config.blocked, !b.allowedCalls.contains(where: { ["referrals", "leaderboards", "codes"].contains($0) }) {
            throw Self.versionBlockedError()
        }
        guard state.installDone, let id = state.installationId else {
            throw ClikgateError(code: ClikgateError.installPending, message: "The first /install hasn't completed yet.")
        }
        if state.identifyPending { await sendIdentify() }
        return ClikgateRequestContext(
            installationId: id, sdkKey: api.sdkKey,
            environment: config.environment ?? options.environment.rawValue,
            apiBaseUrl: options.apiBaseUrl, identityToken: state.identityToken, customerUserId: state.customerUserId,
            sdkVersion: api.sdkVersionHeader, nativeSdkVersion: api.wrapper == nil ? nil : "ios/\(Clikgate.sdkVersion)")
    }

    /// Engage saw a server answer the core must act on. `feature_disabled` is marked off by the
    /// facade synchronously; here the config is refreshed (one attempt, bypassing the 1 h cache).
    func reportServerError(code: String, feature: String?) async {
        switch code {
        case ClikgateError.featureDisabled:
            await refreshConfig(force: true)
        case ClikgateError.invalidSdkKey:
            noteFailure(ClikgateError(code: code, message: "Invalid SDK key", status: 401))
        case ClikgateError.sdkDisabled:
            noteFailure(ClikgateError(code: code, message: "SDK disabled", status: 403))
        case ClikgateError.installationUnknown:
            await recoverIfInstallationUnknown(ClikgateError(code: code, message: "Installation unknown", status: 404))
        default:
            break
        }
    }

    // MARK: - Test hooks

    var isStarted: Bool { started }
    func currentState() -> PersistedState { state.copy() }
}

enum ProcessInfoVersion {
    static var string: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }
}

enum Base64URL {
    static func decode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}

// MARK: - Consent, version policy, Firebase, identity checks, on-device measurement

/// Values collected right before the first `/install` (consent-gated).
struct InstallExtras: Sendable {
    var appInstanceId: String?
    var deviceCheckToken: String?
    var idfv: String?
    var odmInfo: String?
    var odmSdkVersion: String?
    var odmAttempted = false
    /// The first /install of this launch (its attempts and retries), not a later poll: carries the AdServices token
    var sendsSearchAds = false
}

extension ClikgateCore {
    enum ConsentGate: Equatable { case allowed, pending, denied }

    /// Whether consent is required for this device (nil: unknown, no consent config and no hint).
    var consentRequired: Bool? {
        let hint = state.consent.region
        if let c = config.consent {
            switch c.mode {
            case "not_required": return false
            case "required_everywhere": return true
            default:
                if let h = hint { return ConsentRegions.matches(h, c.requiredRegions) }
                return c.required
            }
        }
        if let h = hint { return ConsentRegions.matches(h, ConsentRegions.defaultRequired) }
        return nil
    }

    private var isConsentRequired: Bool { consentRequired ?? false }

    var gate: ConsentGate {
        guard isConsentRequired else { return .allowed }
        switch state.consent.attribution {
        case .granted: return .allowed
        case .unknown: return .pending
        case .denied: return .denied
        }
    }

    /// A purpose is allowed when granted, or when consent isn't required and it isn't denied.
    func allowed(_ p: ClikgateConsentState) -> Bool { p == .granted || (!isConsentRequired && p != .denied) }

    var isBlocked: Bool { config.versionStatus == "blocked" }

    func callAllowed(_ name: String) -> Bool {
        guard isBlocked else { return true }
        return (config.blocked?.allowedCalls ?? SDKCall.blockedDefault).contains(name)
    }

    /// Identity checks need `analytics`, unless the organisation's stated basis is fraud prevention.
    var identityAllowed: Bool {
        !isBlocked && (allowed(state.consent.analytics) || config.consent?.identityChecksBasis == "fraud_prevention")
    }

    static func consentRequiredError() -> ClikgateError {
        ClikgateError(code: ClikgateError.consentRequired,
                      message: "Consent is required for this device and attribution isn't granted; nothing identifying is sent.")
    }

    static func versionBlockedError() -> ClikgateError {
        ClikgateError(code: ClikgateError.sdkVersionBlocked, message: "This Clikgate SDK version is blocked; update the SDK.")
    }

    /// Consent / blocked-version restriction for an SDK call (nil = allowed).
    func callGateError(_ name: String) -> ClikgateError? {
        if !callAllowed(name) { return Self.versionBlockedError() }
        switch gate {
        case .allowed: return nil
        case .pending: return ["config", "opt_out"].contains(name) ? nil : Self.consentRequiredError()
        case .denied: return ["config", "opt_out", "install_ping", "consent"].contains(name) ? nil : Self.consentRequiredError()
        }
    }

    // MARK: Snapshot

    func updateSnapshot() {
        let c = state.consent
        snapshot.consent = ClikgateConsent(analytics: c.analytics, attribution: c.attribution, adUserData: c.adUserData,
                                           adPersonalization: c.adPersonalization, region: c.region,
                                           isRequired: consentRequired)
        var meta: [String: String] = [:]
        let attributionOK = state.trackingEnabled && !serverOptedOut && (!isConsentRequired || c.attribution == .granted)
        if attributionOK {
            if state.lastClickId != nil || state.lastLinkId != nil {
                meta["cg_click_id"] = state.lastClickId
                meta["cg_link_id"] = state.lastLinkId
            } else if let a = state.attribution, a.status == .attributed {
                meta["cg_click_id"] = a.clickId
                meta["cg_link_id"] = a.link?.id
            }
        }
        snapshot.metadata = meta
    }

    // MARK: Consent changes

    func setConsent(analytics: ClikgateConsentState?, attribution: ClikgateConsentState?,
                    adUserData: ClikgateConsentState?, adPersonalization: ClikgateConsentState?) async {
        var c = state.consent
        if let v = analytics { c.analytics = v }
        if let v = attribution { c.attribution = v }
        if let v = adUserData { c.adUserData = v }
        if let v = adPersonalization { c.adPersonalization = v }
        let changed = c.analytics != state.consent.analytics || c.attribution != state.consent.attribution
            || c.adUserData != state.consent.adUserData || c.adPersonalization != state.consent.adPersonalization
        c.updatedAt = deps.clock.now()
        state.consent = c
        if changed { state.consentRecordPending = true }
        save()
        updateSnapshot()
        guard started else { return }
        await consentDidChange()
    }

    func setConsentRegion(_ region: String?) async {
        guard region != state.consent.region else { return }
        state.consent.region = region
        state.consentRecordPending = true
        save()
        updateSnapshot()
        guard started else { return }
        await refreshConfig(force: true)
        applyVersionPolicy()
        updateSnapshot()
        await consentDidChange()
    }

    private func consentDidChange() async {
        guard isActive else { return }
        if await consentAllowsProgress() {
            let freshInstall = !state.installDone
            if freshInstall { await runInstall() }
            await afterConsentGranted()
            await registerForPushIfNeeded()
            if !freshInstall { await flush() }
        }
    }

    /// Applies the consent gate: buffering bookkeeping (pending) or the drop + install ping /
    /// consent record (denied). Returns true when normal operation may continue.
    func consentAllowsProgress() async -> Bool {
        switch gate {
        case .allowed:
            if state.consentPendingSince != nil {
                expireConsentBuffer()          // drop what expired while buffering, then flush the rest
                state.consentPendingSince = nil
                save()
            }
            queue.maxEvents = config.batching.maxQueueEvents
            return true
        case .pending:
            if state.consentPendingSince == nil { state.consentPendingSince = deps.clock.now(); save() }
            expireConsentBuffer()
            // First-launch signals are collected now and kept on the device until grant.
            if !state.installDone && state.trackingEnabled { await collectFirstLaunchSignals() }
            logger.info("Consent is required and attribution is unknown: buffering on the device")
            return false
        case .denied:
            dropConsentBuffer()
            if state.installDone {
                await sendConsentIfPending()
            } else {
                await sendInstallPingIfNeeded()
            }
            return false
        }
    }

    /// After consent allows attribution: the kept URLs (silently) and the consent record.
    func afterConsentGranted() async {
        guard gate == .allowed, state.installDone else { return }
        await sendConsentIfPending()
        let urls = state.keptUrls
        state.keptUrls = []
        if !urls.isEmpty { save() }
        for u in urls { if let url = URL(string: u) { await resolve(url: url, deliver: false) } }
        logFirebaseAttributionIfNeeded()
    }

    private func dropConsentBuffer() {
        if queue.count > 0 || !state.keptUrls.isEmpty || state.pasteboardToken != nil || state.launchUrl != nil {
            logger.info("Consent denied: dropping buffered events and links")
        }
        refuseQueued("consent_denied")
        queue.clear()
        state.keptUrls = []
        state.pasteboardToken = nil
        state.pasteboardOutcome = nil
        adServicesToken = nil
        state.launchUrl = nil
        state.launchUrlDeliveredLocally = false
        state.pendingOpenClickIds = nil
        state.consentPendingSince = nil
        save()
    }

    /// While buffering: drop events older than `buffer_max_days` (expiry).
    func expireConsentBuffer() {
        let days = Double(config.consent?.bufferMaxDays ?? 7)
        let n = queue.dropOlder(than: deps.clock.now().addingTimeInterval(-days * 86_400))
        if n > 0 { logger.info("Consent buffer: dropped \(n) expired event(s)") }
    }

    /// While buffering the queue holds at most `buffer_max_events` (oldest dropped).
    func applyBufferLimits() {
        let limit = Swift.min(config.batching.maxQueueEvents, config.consent?.bufferMaxEvents ?? 1000)
        queue.maxEvents = Swift.max(1, limit)
        queue.trim()
    }

    func sendConsentIfPending() async {
        guard state.consentRecordPending, state.installDone, isActive, gate != .pending, callAllowed("consent") else { return }
        let result = await call("POST", "v1/sdk/consent", body: encode(["consent": state.consent.json()]), retry: .attempts(5))
        if case .success = result { state.consentRecordPending = false; save() }
    }

    private func sendInstallPingIfNeeded() async {
        guard !state.installPingSent, config.consent?.anonymousCounts == true, callAllowed("install_ping") else { return }
        let body: JSONObject = ["platform": "ios", "app_version": BundleInfo.appVersion(), "sdk_version": Clikgate.sdkVersion,
                                "consent": state.consent.json()]
        let result = await call("POST", "v1/sdk/install-ping", body: encode(body), retry: .attempts(5))
        if case .success = result { state.installPingSent = true; save() }
    }

    // MARK: Version policy

    func applyVersionPolicy() {
        guard !versionPolicyLogged else { return }
        let own = api.wrapper?.version ?? Clikgate.sdkVersion
        let status = config.versionStatus
            ?? (config.minSupportedVersion.map { SemVer.compare(own, $0) < 0 ? "deprecated" : "supported" })
        switch status {
        case "blocked":
            versionPolicyLogged = true
            logger.error(config.blocked?.message ?? "Clikgate SDK \(own) is blocked; only basic calls are made. Update the SDK.")
        case "deprecated":
            versionPolicyLogged = true
            let latest = config.latestVersion.map { " Update to \($0)." } ?? " Update the SDK."
            logger.warning("Clikgate SDK \(own) is deprecated.\(latest)")
        default:
            break
        }
    }

    // MARK: Install extras (identity checks, Firebase, on-device measurement)

    func collectInstallExtras() async -> InstallExtras {
        var x = InstallExtras()
        guard !isBlocked else { return x }
        x.appInstanceId = await currentAppInstanceId(wait: true)
        if identityAllowed {
            let checks = config.features.identityChecks || attestationEnabled
            if checks && deps.deviceCheck.isSupported { x.deviceCheckToken = await deps.deviceCheck.token() }
            // IDFV also links an Apple Ads `Redownload` to the earlier install (same consent rule)
            if checks || config.features.appleSearchAds { x.idfv = await deps.vendorId() }
        }
        if odmEnabled, !state.odmCollected, state.consent.adUserData != .denied, deps.onDeviceMeasurement.isAvailable {
            x.odmAttempted = true
            if let r = await deps.onDeviceMeasurement.installInfo(firstLaunch: state.firstLaunchAt ?? deps.clock.now()) {
                x.odmInfo = r.info
                x.odmSdkVersion = r.sdkVersion
            }
        }
        return x
    }

    func enableGoogleOnDeviceMeasurement() { odmEnabled = true }

    // MARK: Firebase forwarding

    func enableFirebaseForwarding(_ options: ClikgateFirebaseForwardingOptions) {
        firebaseOptions = options
        logFirebaseAttributionIfNeeded()
    }

    private var firebaseActive: Bool {
        guard firebaseOptions != nil, config.firebase?.enabled == true, isActive, !isBlocked,
              allowed(state.consent.analytics), gate == .allowed else { return false }
        return deps.firebase.isAvailable
    }

    func currentAppInstanceId(wait: Bool) async -> String? {
        guard firebaseActive, config.firebase?.reportAppInstanceId != false else { return nil }
        for i in 0..<(wait ? 8 : 1) {
            if let id = deps.firebase.appInstanceID(), !id.isEmpty { return id }
            if i < 7 && wait { await deps.clock.sleep(seconds: 0.25) }
        }
        return nil
    }

    func logFirebaseAttributionIfNeeded() {
        guard !state.firebaseAttributionLogged, let opts = firebaseOptions, firebaseActive,
              let cfg = config.firebase, let a = state.attribution, a.status != .pending else { return }
        if opts.logAttributionEvent && cfg.logAttributionEvent {
            var p: [String: Any] = [:]
            func put(_ k: String, _ v: String?) { if let v = v { p[k] = FirebaseLimits.truncate(v, FirebaseLimits.maxStringValue) } }
            put("cg_source", a.source)
            put("cg_medium", a.medium)
            put("cg_campaign", a.campaign)
            put("cg_channel", a.status == .organic ? "organic" : a.channel)
            put("cg_link_id", a.link?.id)
            put("cg_match_type", a.matchType)
            deps.firebase.logEvent("clikgate_attribution", parameters: p)
        }
        if opts.setUserProperties && cfg.setUserProperties {
            let src = a.status == .organic ? (a.source ?? "organic") : a.source
            deps.firebase.setUserProperty(src.map { FirebaseLimits.truncate($0, FirebaseLimits.maxUserPropertyValue) }, forName: "cg_first_source")
            deps.firebase.setUserProperty(a.campaign.map { FirebaseLimits.truncate($0, FirebaseLimits.maxUserPropertyValue) }, forName: "cg_first_campaign")
        }
        state.firebaseAttributionLogged = true
        save()
    }

    // MARK: Local deep links

    static func localDeepLink(_ url: URL) -> ClikgateDeepLinkResult {
        var data: [String: JSONValue] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            data[item.name] = .string(item.value ?? "")
        }
        return ClikgateDeepLinkResult(url: url, path: url.path.isEmpty ? nil : url.path, dataJSON: data, isDeferred: false,
                                      clickId: LinkMatcher.clickId(in: url), matchType: nil, link: nil, referral: nil)
    }
}

extension ClikgateCore {
    /// Applies the consent, Firebase and measurement calls the app made before `configure` (the core hasn't started yet, so
    /// nothing is sent here) and publishes the persisted consent to the facade's snapshot.
    func prepare(consent: (ClikgateConsentState?, ClikgateConsentState?, ClikgateConsentState?, ClikgateConsentState?)?,
                 region: (value: String?, set: Bool), firebase: ClikgateFirebaseForwardingOptions?, odm: Bool) {
        if let x = consent {
            var c = state.consent
            if let v = x.0 { c.analytics = v }
            if let v = x.1 { c.attribution = v }
            if let v = x.2 { c.adUserData = v }
            if let v = x.3 { c.adPersonalization = v }
            if c.analytics != state.consent.analytics || c.attribution != state.consent.attribution
                || c.adUserData != state.consent.adUserData || c.adPersonalization != state.consent.adPersonalization {
                state.consentRecordPending = true
            }
            c.updatedAt = deps.clock.now()
            state.consent = c
        }
        if region.set && region.value != state.consent.region {
            state.consent.region = region.value
            state.consentRecordPending = true
        }
        if consent != nil || region.set { save() }
        if let f = firebase { firebaseOptions = f }
        if odm { odmEnabled = true }
        updateSnapshot()
    }
}
