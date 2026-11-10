import Foundation
import UIKit

/// Clikgate SDK entry point.
///
/// ```swift
/// Clikgate.configure(sdkKey: "cg_sdk_...", options: ClikgateOptions(linkDomains: ["inv.myapp.com"]))
/// Clikgate.shared.onDeepLink { result in router.open(result.path) }
/// ```
///
/// All methods are thread-safe and return immediately; callbacks run on the main thread.
@objc(Clikgate)
public final class Clikgate: NSObject, @unchecked Sendable {
    /// The native SDK version.
    public static let sdkVersion = "2.0.0"

    @objc public static let shared = Clikgate()

    /// Referee-side referral calls: `applyCode` and `referredBy` (feature `referrals`).
    public let referrals: ClikgateReferrals

    private let lock = NSLock()
    private var core: ClikgateCore?
    private var wrapper: WrapperInfo?
    private var observers: [NSObjectProtocol] = []
    let dispatcher = DeepLinkDispatcher()
    private(set) var linkDomains = LinkDomainsBox(optionDomains: [])
    private var appSchemes: [String] = []
    private var deferredTimeout: TimeInterval = 5
    /// URLs received before `configure` (e.g. a Universal Link that launched a Flutter app
    /// before Dart called configure). Re-evaluated right after configure; latest 10 kept.
    private var preConfigureURLs: [URL] = []
    let logger = ClikgateLogger(level: .warning)
    /// Consent / metadata answered synchronously (shared with the core once configured).
    let snapshot = SyncSnapshot()
    // Calls made before `configure`, applied right after it.
    private var preConsent: (ClikgateConsentState?, ClikgateConsentState?, ClikgateConsentState?, ClikgateConsentState?)?
    private var preRegion: (value: String?, set: Bool) = (nil, false)
    private var preFirebase: ClikgateFirebaseForwardingOptions?
    private var preODM = false

    /// Use `Clikgate.shared`. (Internal so tests can create isolated instances.)
    override init() {
        referrals = ClikgateReferrals()
        super.init()
        referrals.owner = self
    }

    // MARK: - Configuration

    /// Configure once, as early as possible (`application(_:didFinishLaunchingWithOptions:)`).
    /// Returns immediately; work happens in the background.
    public static func configure(sdkKey: String, options: ClikgateOptions = ClikgateOptions()) {
        shared.configure(sdkKey: sdkKey, options: options, deps: .live(), startTimers: true)
    }

    /// Wrappers (Flutter, React Native) call this before `configure` so headers report both SDKs.
    @_spi(ClikgateWrapper)
    public static func setWrapper(name: String, version: String) {
        shared.lock.lock()
        shared.wrapper = WrapperInfo(name: name, version: version)
        shared.lock.unlock()
    }

    func configure(sdkKey: String, options: ClikgateOptions, deps: ClikgateDependencies, startTimers: Bool) {
        lock.lock()
        if core != nil {
            lock.unlock()
            logger.warning("Clikgate.configure was called more than once; ignoring")
            return
        }
        logger.level = options.logLevel
        guard sdkKey.hasPrefix("cg_sdk_") else {
            lock.unlock()
            logger.error("Clikgate.configure: the SDK key must start with cg_sdk_")
            return
        }
        let domains = LinkDomainsBox(optionDomains: options.linkDomains)
        linkDomains = domains
        appSchemes = deps.appURLSchemes
        deferredTimeout = options.deferredDeepLinkTimeout
        let c = ClikgateCore(sdkKey: sdkKey, options: options, deps: deps, logger: logger,
                             dispatcher: dispatcher, linkDomains: domains, wrapper: wrapper, snapshot: snapshot)
        core = c
        let early = preConfigureURLs
        preConfigureURLs = []
        let consent = preConsent, region = preRegion, firebase = preFirebase, odm = preODM
        preConsent = nil; preRegion = (nil, false); preFirebase = nil; preODM = false
        lock.unlock()

        let inBackground = Self.isApplicationInBackground()
        Task {
            await c.prepare(consent: consent, region: region, firebase: firebase, odm: odm)
            await c.start(launchedInBackground: inBackground, startTimers: startTimers)
        }
        if startTimers { observeLifecycle(c) }
        for url in early { handle(url: url) }
    }

    private static func isApplicationInBackground() -> Bool {
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated { UIApplication.shared.applicationState == .background }
    }

    private func observeLifecycle(_ c: ClikgateCore) {
        let nc = NotificationCenter.default
        let bg = nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task {
                await c.appDidEnterBackground()
                await c.flushInBackground()
            }
        }
        let fg = nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            Task { await c.appWillEnterForeground() }
        }
        lock.lock()
        observers = [bg, fg]
        lock.unlock()
    }

    var currentCore: ClikgateCore? {
        lock.lock(); defer { lock.unlock() }
        return core
    }

    /// Whether `configure` has run (for wrappers).
    @_spi(ClikgateWrapper)
    public var isConfigured: Bool { currentCore != nil }

    // MARK: - Feature switches (v3)

    /// Whether an organisation feature (``ClikgateFeatures``: `referrals`, `leaderboards`,
    /// `offline_codes`, `identity_checks`, ...) is switched on for this app.
    ///
    /// Answers synchronously from the cached `/v1/sdk/config` (refreshed on launch, at most hourly).
    /// Before the first config fetch (or before `configure`), and for features an older server
    /// doesn't list, the catalogue defaults apply: `referrals`, `leaderboards`, `offline_codes`,
    /// `app_attribution` and `deep_linking` on, everything else off. Unknown keys are off. A feature the server just
    /// answered `feature_disabled` for reads as off until the next config fetch.
    ///
    /// Calls of a switched-off feature fail with ``ClikgateError/featureDisabled`` without a
    /// network call, so checking first is only needed to hide UI.
    public func isFeatureEnabled(_ key: String) -> Bool {
        guard let c = currentCore else { return FeatureSwitches.isEnabled(key, switches: nil) }
        return c.features.isEnabled(key)
    }

    // MARK: - Engage add-on (internal)

    /// **Internal**, for the `ClikgateEngage` add-on: the request context for a `/v1/sdk` call.
    /// Throws `not_configured`, `opted_out`, `invalid_sdk_key`, `sdk_disabled` or `install_pending`;
    /// sends a pending identify first.
    @_spi(ClikgateEngage)
    public func requestContext() async throws -> ClikgateRequestContext {
        guard let c = currentCore else { throw ClikgateError.notConfiguredError() }
        return try await c.requestContext()
    }

    /// **Internal**, for the `ClikgateEngage` add-on: a server answer the core must act on.
    /// `feature_disabled` marks `feature` off until the next config fetch (and refreshes the config
    /// in the background); `invalid_sdk_key`, `sdk_disabled` and `installation_unknown` apply the
    /// core's global error rules. Other codes are ignored.
    @_spi(ClikgateEngage)
    public func reportServerError(code: String, feature: String?) {
        guard let c = currentCore else { return }
        if code == ClikgateError.featureDisabled, let f = feature { c.features.markDisabled(f) }
        Task { await c.reportServerError(code: code, feature: feature) }
    }

    // MARK: - Deep links

    /// Handles a URL the app was opened with (custom scheme or Universal Link).
    /// Returns true when it's a Clikgate link; the result arrives on `onDeepLink`.
    @objc(handleURL:)
    @discardableResult
    public func handle(url: URL) -> Bool {
        lock.lock()
        guard let c = core else {
            preConfigureURLs.append(url)
            if preConfigureURLs.count > 10 { preConfigureURLs.removeFirst() }
            lock.unlock()
            logger.info("handle(url:) before configure: handled after configure")
            return false
        }
        lock.unlock()
        guard LinkMatcher.isClikgateURL(url, linkDomains: linkDomains.all, appSchemes: appSchemes) else { return false }
        Task { await c.resolve(url: url) }
        return true
    }

    /// Handles a Universal Link (`NSUserActivityTypeBrowsingWeb`). Returns true when it's a Clikgate link.
    @objc(continueUserActivity:)
    @discardableResult
    public func `continue`(userActivity: NSUserActivity) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL else { return false }
        return handle(url: url)
    }

    /// Registers the deep link handler (deferred and direct links). Links that arrived before
    /// registration (latest 10) are delivered right away. Called on the main thread.
    public func onDeepLink(_ handler: @escaping @MainActor @Sendable (ClikgateDeepLinkResult) -> Void) {
        dispatcher.setHandler(handler)
    }

    /// Posted (main thread) after the SDK showed another organisation's shared-domain link in an
    /// in-app browser instead of delivering a deep link; `object` is the link's `URL`.
    public static let browserHandoffNotification = Notification.Name("ClikgateBrowserHandoff")

    /// Removes the deep link handler; later links are buffered again.
    public func removeDeepLinkHandler() {
        dispatcher.setHandler(nil)
    }

    // MARK: - Attribution

    /// Install attribution. Waits up to `deferredDeepLinkTimeout` for the first `/install`,
    /// then resolves with `status == .pending`.
    public func attribution() async throws -> ClikgateAttribution {
        guard let c = currentCore else { throw ClikgateError.notConfiguredError() }
        return await c.attribution(timeout: deferredTimeout)
    }

    public func attribution(completion: @escaping @MainActor @Sendable (Result<ClikgateAttribution, ClikgateError>) -> Void) {
        Task {
            let result: Result<ClikgateAttribution, ClikgateError>
            if let c = currentCore {
                result = .success(await c.attribution(timeout: deferredTimeout))
            } else {
                result = .failure(.notConfiguredError())
            }
            await MainActor.run { completion(result) }
        }
    }

    // MARK: - Goals

    /// Sends a goal: an outcome your business chose (`account_opened`, `loan_disbursed`, `purchase`), attributed
    /// to the click or install that brought this user. It is the one method for what happens in your app, Standard
    /// or Payment:
    /// `Clikgate.shared.goal("account_opened", value: 2_000_000, currency: "NGN", reference: "APP-55231")` or, for a
    /// Payment goal, `Clikgate.shared.goal("purchase", reference: "T123456", provider: .paystack)`.
    ///
    /// The goal's kind is set in the dashboard, never in the call. A Payment goal needs `reference` (the payment
    /// reference your checkout returned) and `provider`; it waits until your payment provider or server confirms
    /// it, and any `value` is ignored (the amount comes from the confirmation).
    ///
    /// `value` is in normal units (never kobo or cents), ≥ 0, at most 15 significant digits, sent as a decimal
    /// string. `reference` is your own unique id (1–128 characters; a UUID is generated when nil). Validated
    /// locally (key `^[a-z][a-z0-9_]*$`, 2–40 characters; currency ISO 4217). Queued, retried and
    /// consent-buffered, idempotent by `(key, reference)`, and sent in private mode too. Works on every plan. A name
    /// counts once it's ticked in the dashboard ("Count this as a goal"). Never put customer data in a goal.
    ///
    /// `completion` gets the result on the main queue once Clikgate answers: `status` `.counted`, `.waiting` (a
    /// Payment goal waiting for its confirmation), `.received` (stored, not counted: the name isn't ticked yet; not
    /// retried) or `.refused`, with a `reason`. Invalid input is refused at once
    /// (`invalid_argument`). While offline the goal stays queued and `completion` waits; it isn't called if the
    /// app quits first (the goal is still sent on the next launch).
    public func goal(_ key: String, value: Decimal? = nil, currency: String? = nil, reference: String? = nil,
                     provider: ClikgateProvider? = nil, isFirst: Bool? = nil, label: String? = nil,
                     completion: (@MainActor @Sendable (ClikgateGoalResult) -> Void)? = nil) {
        // NaN / negative → "-", which validation rejects.
        goal(key, decimalString: value.map { Goals.wire($0) ?? "-" }, currency: currency, reference: reference,
             providerKey: provider?.rawValue, isFirst: isFirst, label: label, completion: completion)
    }

    /// `goal` with the value as a decimal string (`"1500.50"`) and the provider as its key (`"paystack"`), for the
    /// Flutter and React Native wrappers. A malformed provider key is refused (`invalid_argument`).
    public func goal(_ key: String, decimalString value: String?, currency: String? = nil, reference: String? = nil,
                     providerKey: String? = nil, isFirst: Bool? = nil, label: String? = nil,
                     completion: (@MainActor @Sendable (ClikgateGoalResult) -> Void)? = nil) {
        let finish: @Sendable (ClikgateGoalResult) -> Void = { r in
            if let completion = completion { DispatchQueue.main.async { completion(r) } }
        }
        guard let c = currentCore else { return finish(.refused(ClikgateError.notConfigured)) }
        Task {
            await c.goal(key, value: value, currency: currency, reference: reference, provider: providerKey,
                         isFirst: isFirst, label: label, done: finish)
        }
    }

    // MARK: - Identity

    /// Tells Clikgate who this user is: an optional `label` your team sees instead of the click ID (1-80
    /// characters, "" clears it; Growth and up), your `customerId` (nil clears it; leave it out to keep it) and an
    /// `identityToken` from your backend (for referral programs with `require_identity_token`). With nothing to
    /// send it's a no-op. In private mode the customer ID and token are dropped on the device, and the label too
    /// unless your organisation allows labels in private mode.
    ///
    /// Identity Path A (the default): your server makes the token with the server SDK's `createIdentityToken` (it
    /// reads `CLIKGATE_IDENTITY_SECRET`; the secret never goes in the app) and returns it in the sign-in and "current
    /// user" responses; pass the newest one here. Call after sign-in or sign-up and at app open when already signed
    /// in; on sign-out call `identifyUser(customerId: nil)`. Path B needs no token: see ``installationId()``.
    /// Guide: https://clikgate.com/docs/identify-users
    public func identifyUser(label: String? = nil, customerId: String? = "\u{0}", identityToken: String? = nil) {
        guard let c = currentCore else { logger.warning("identifyUser called before configure"); return }
        Task { await c.identifyUser(label: label, customerId: customerId, identityToken: identityToken) }
    }

    /// This installation's ID: the random UUID the SDK created at first launch and sends to Clikgate with every call
    /// (not personal data; allowed in private mode). For identity Path B, include it in the sign-in request to your
    /// own server (and at every signed-in app open); your server calls the server SDK's
    /// `identifyUser({appId, installationId, customerId, label?})`. No identity secret or token is needed.
    ///
    /// `try await Clikgate.shared.installationId()`. Right after `configure` it waits for the first launch's config
    /// answer (a few seconds at most; offline it answers at once). A reinstall gets a new ID. Returns nil when
    /// tracking is off (`setTrackingEnabled(false)`, consent denied or not given yet where it's required, or
    /// deep-link-only mode), so your server simply skips `identifyUser`. Throws `not_configured` before `configure`.
    /// Guide: https://clikgate.com/docs/identify-users
    public func installationId() async throws -> String? {
        guard let c = currentCore else { throw ClikgateError.notConfiguredError() }
        return await c.installationIdForApp()
    }

    /// Completion form of ``installationId()`` (main queue), for the Flutter and React Native wrappers.
    public func installationId(completion: @escaping @MainActor @Sendable (Result<String?, ClikgateError>) -> Void) {
        Task {
            let result: Result<String?, ClikgateError>
            if let c = currentCore { result = .success(await c.installationIdForApp()) } else { result = .failure(.notConfiguredError()) }
            await MainActor.run { completion(result) }
        }
    }

    // MARK: - Opt-out

    /// `false` stops all processing (clears the goal queue, tells the server to erase device fields).
    public func setTrackingEnabled(_ enabled: Bool) {
        guard let c = currentCore else { logger.warning("setTrackingEnabled called before configure"); return }
        Task { await c.setTrackingEnabled(enabled) }
    }

    // MARK: - Push / uninstall tracking

    /// APNs device token from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    @objc(setPushTokenWithDeviceToken:)
    public func setPushToken(deviceToken: Data) {
        setPushToken(PushTokens.hex(deviceToken), provider: "apns")
    }

    /// FCM registration token (apps that use Firebase Messaging on iOS).
    @objc(setPushTokenWithFcmToken:)
    public func setPushToken(fcmToken: String) {
        setPushToken(fcmToken, provider: "fcm")
    }

    /// Wrappers: `provider` is `apns` (hex device token) or `fcm`.
    @_spi(ClikgateWrapper)
    public func setPushToken(_ token: String, provider: String) {
        guard let c = currentCore else { logger.warning("setPushToken called before configure"); return }
        Task { await c.setPushToken(token, provider: provider) }
    }

    /// Returns true for Clikgate uninstall-check pushes; call `completionHandler(.noData)` and stop.
    /// Never shows anything and never requests notification permission.
    @objc(handleRemoteNotification:)
    public func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        RemoteNotification.isClikgateMessage(userInfo)
    }

    /// Pure check usable anywhere (notification service extensions, before configure).
    @objc public static func isClikgateMessage(_ userInfo: [AnyHashable: Any]) -> Bool {
        RemoteNotification.isClikgateMessage(userInfo)
    }

    // MARK: - Consent

    /// Sets consent purposes; nil leaves a purpose unchanged. Consent is stored on the device and
    /// sent with every request. When consent is required for this device (EEA, UK and Switzerland by
    /// default, configured in the dashboard) and `attribution` is `unknown`, the SDK buffers on the
    /// device (up to 7 days or 1,000 goals) and sends nothing identifying; `granted` flushes the
    /// buffer, `denied` drops it. May be called before `configure`.
    public func setConsent(analytics: ClikgateConsentState? = nil, attribution: ClikgateConsentState? = nil,
                           adUserData: ClikgateConsentState? = nil, adPersonalization: ClikgateConsentState? = nil) {
        lock.lock()
        guard let c = core else {
            let p = preConsent
            preConsent = (analytics ?? p?.0, attribution ?? p?.1, adUserData ?? p?.2, adPersonalization ?? p?.3)
            var s = snapshot.consent
            if let v = analytics { s.analytics = v }
            if let v = attribution { s.attribution = v }
            if let v = adUserData { s.adUserData = v }
            if let v = adPersonalization { s.adPersonalization = v }
            snapshot.consent = s
            lock.unlock()
            return
        }
        lock.unlock()
        Task { await c.setConsent(analytics: analytics, attribution: attribution, adUserData: adUserData, adPersonalization: adPersonalization) }
    }

    /// The consent the app set (all `unknown` until then), the region hint, and whether consent is
    /// required for this device (nil while unknown).
    public func getConsent() -> ClikgateConsent { snapshot.consent }

    /// Region hint for the consent decision: `EEA`, `UK` or an ISO 3166-1 alpha-2 country code
    /// (`"DE"`); nil clears it. Invalid values are logged and ignored. May be called before `configure`.
    public func setConsentRegion(_ region: String?) {
        _ = setConsentRegionValidated(region)
    }

    /// Wrappers: like ``setConsentRegion(_:)`` but returns false for an invalid region.
    @_spi(ClikgateWrapper)
    @discardableResult
    public func setConsentRegionValidated(_ region: String?) -> Bool {
        let normalized = ConsentRegions.normalize(region)
        if region != nil && normalized == nil {
            logger.error("setConsentRegion: '\(region ?? "")' isn't EEA, UK or a two-letter country code; ignored")
            return false
        }
        lock.lock()
        guard let c = core else {
            preRegion = (normalized, true)
            var s = snapshot.consent
            s.region = normalized
            snapshot.consent = s
            lock.unlock()
            return true
        }
        lock.unlock()
        Task { await c.setConsentRegion(normalized) }
        return true
    }

    // MARK: - Firebase forwarding, sales metadata, Google on-device measurement

    /// Sends Clikgate attribution to Firebase Analytics in this app (`clikgate_attribution` event,
    /// `cg_first_source` / `cg_first_campaign` user properties, optional event mirroring) and reports
    /// the Firebase app instance id. Needs Firebase Analytics in the app (detected at runtime; no
    /// dependency), the app's Firebase forwarding switch in Clikgate, and `analytics` consent.
    /// Call on every launch.
    public func enableFirebaseForwarding(_ options: ClikgateFirebaseForwardingOptions = ClikgateFirebaseForwardingOptions()) {
        lock.lock()
        guard let c = core else { preFirebase = options; lock.unlock(); return }
        lock.unlock()
        Task { await c.enableFirebaseForwarding(options) }
    }

    /// `["cg_click_id": ..., "cg_link_id": ...]` of the latest Clikgate link that opened the app (else
    /// the install attribution), for Paystack `metadata` / Flutterwave `meta` at checkout. Empty when
    /// nothing is attributed, tracking is off, or consent is required and attribution isn't granted.
    public func attributionMetadata() -> [String: String] { snapshot.metadata }

    /// Sends Google's on-device conversion measurement info (GoogleAdsOnDeviceConversion SDK, which
    /// the app links itself) with the first install. Call before `configure` on the first launch.
    public func enableGoogleOnDeviceMeasurement() {
        lock.lock()
        guard let c = core else { preODM = true; lock.unlock(); return }
        lock.unlock()
        Task { await c.enableGoogleOnDeviceMeasurement() }
    }

    // MARK: - Pasteboard (.pasteControlOnly)

    func applyPastedText(_ text: String?) async -> Bool {
        guard let c = currentCore else { return false }
        return await c.applyPastedText(text)
    }
}
