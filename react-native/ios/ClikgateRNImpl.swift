import Foundation
import UIKit
@_spi(ClikgateWrapper) @_spi(ClikgateEngage) import Clikgate

/// Swift implementation behind the `Clikgate` TurboModule (RNClikgate.mm). Implements
/// the bridge protocol over the native Clikgate iOS SDK; no attribution or referral logic.
///
/// Only Foundation types cross into Objective-C++ (the generated header is imported from a `.mm`
/// file, where `@import Clikgate` is not available).
@objc(ClikgateRNImpl)
public final class ClikgateRNImpl: NSObject {
    public typealias Resolve = (Any?) -> Void
    public typealias Reject = (_ code: String, _ message: String, _ userInfo: [String: Any]) -> Void

    /// Called with each deep-link event map when JS listens (set by RNClikgate.mm).
    @objc public var emitter: (([String: Any]) -> Void)? {
        didSet { DeepLinkHub.shared.attach(self) }
    }

    @objc public override init() {
        super.init()
        DeepLinkHub.shared.install()
    }

    /// JS listener presence (RCTEventEmitter startObserving / stopObserving).
    @objc public func setHasListeners(_ hasListeners: Bool) {
        DeepLinkHub.shared.setHasListeners(hasListeners, for: self)
    }

    @objc public func invalidate() {
        DeepLinkHub.shared.detach(self)
    }

    fileprivate func emit(_ event: [String: Any]) {
        emitter?(event)
    }

    // MARK: - Methods

    @objc public func configure(_ args: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        let args = args as? [String: Any] ?? [:]
        guard let sdkKey = args["sdkKey"] as? String, sdkKey.hasPrefix("cg_sdk_") else {
            Self.invalid(reject, "sdkKey must be a Clikgate SDK key (cg_sdk_...)", param: "sdkKey"); return
        }
        // JS reloads re-run configure: the native SDK keeps running with the first configuration.
        if Clikgate.shared.isConfigured { resolve(nil); return }

        var options = ClikgateOptions()
        options.linkDomains = (args["linkDomains"] as? [String]) ?? []
        if let base = args["apiBaseUrl"] as? String, !base.isEmpty {
            guard let url = URL(string: base), url.scheme != nil else {
                Self.invalid(reject, "apiBaseUrl must be an absolute URL", param: "apiBaseUrl"); return
            }
            options.apiBaseUrl = url
        }
        switch args["logLevel"] as? String {
        case "verbose": options.logLevel = .verbose
        case "debug": options.logLevel = .debug
        case "info": options.logLevel = .info
        case "error": options.logLevel = .error
        case "none": options.logLevel = .none
        default: options.logLevel = .warning
        }
        options.environment = (args["environment"] as? String) == "sandbox" ? .sandbox : .production
        options.attestation = (args["attestation"] as? String) == "ifAvailable" ? .appAttestIfAvailable : .off
        switch args["pasteboardMode"] as? String {
        case "automatic": options.pasteboardMode = .automatic
        case "pasteControlOnly": options.pasteboardMode = .pasteControlOnly
        default: options.pasteboardMode = .off   // opt-in clipboard deferred link
        }
        options.waitForATT = (args["waitForATT"] as? Bool) ?? false
        if let ms = (args["deferredDeepLinkTimeoutMs"] as? NSNumber)?.doubleValue, ms >= 0 {
            options.deferredDeepLinkTimeout = ms / 1000
        }
        options.platformDomainBrowserFallback = (args["platformDomainBrowserFallback"] as? Bool) ?? true
        options.automaticPushToken = (args["automaticPushToken"] as? Bool) ?? true
        Clikgate.setWrapper(name: ClikgateRN.wrapperName, version: (args["wrapperVersion"] as? String) ?? "0.0.0")
        Clikgate.configure(sdkKey: sdkKey, options: options)
        ClikgateRN.didConfigure()
        resolve(nil)
    }

    @objc public func sdkVersion(_ resolve: @escaping Resolve) {
        resolve(Clikgate.sdkVersion)
    }

    @objc public func handleUrl(_ args: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        guard let s = args["url"] as? String, let url = URL(string: s) else {
            Self.invalid(reject, "url must be a valid URL string", param: "url"); return
        }
        resolve(Clikgate.shared.handle(url: url))
    }

    @objc public func getAttribution(_ args: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        guard Self.requireConfigured(reject) else { return }
        Clikgate.shared.attribution { r in
            switch r {
            case .success(let a): resolve(Self.map(a))
            case .failure(let e): Self.reject(reject, e)
            }
        }
    }

    /// Identity Path B. Resolves `{installationId}`; null when tracking is off.
    @objc public func getInstallationId(_ args: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        guard Self.requireConfigured(reject) else { return }
        Clikgate.shared.installationId { r in
            switch r {
            case .success(let id): resolve(["installationId": (id as Any?) ?? NSNull()])
            case .failure(let e): Self.reject(reject, e)
            }
        }
    }

    /// The value arrives as a decimal string; resolves with the goal's result.
    @objc public func goal(_ args: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        guard let key = args["key"] as? String else { Self.invalid(reject, "key is required", param: "goal"); return }
        Clikgate.shared.goal(key, decimalString: args["value"] as? String, currency: args["currency"] as? String,
                             reference: args["reference"] as? String, providerKey: args["provider"] as? String,
                             isFirst: args["isFirst"] as? Bool, label: args["label"] as? String) { r in
            let kind: Any = r.goalKind.map { "\($0)" } ?? NSNull()
            resolve(["status": "\(r.status)", "reason": (r.reason as Any?) ?? NSNull(),
                     "goalKind": kind, "valueIgnored": r.valueIgnored])
        }
    }

    /// `customerId` absent keeps the stored one; null clears it.
    @objc public func identifyUser(_ args: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        guard Self.requireConfigured(reject) else { return }
        let label = args["label"] as? String, token = args["identityToken"] as? String
        if args["customerId"] != nil {
            Clikgate.shared.identifyUser(label: label, customerId: args["customerId"] as? String, identityToken: token)
        } else {
            Clikgate.shared.identifyUser(label: label, identityToken: token)
        }
        resolve(nil)
    }

    @objc public func setTrackingEnabled(_ args: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        guard Self.requireConfigured(reject) else { return }
        guard let enabled = args["enabled"] as? Bool else { Self.invalid(reject, "enabled is required", param: "enabled"); return }
        Clikgate.shared.setTrackingEnabled(enabled)
        resolve(nil)
    }

    @objc public func setPushToken(_ args: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        guard Self.requireConfigured(reject) else { return }
        guard let token = args["token"] as? String, !token.isEmpty else {
            Self.invalid(reject, "token is required", param: "token"); return
        }
        let provider = (args["provider"] as? String) ?? "fcm"
        guard provider == "fcm" || provider == "apns" else {
            Self.invalid(reject, "provider must be fcm or apns", param: "provider"); return
        }
        Clikgate.shared.setPushToken(provider == "apns" ? token.lowercased() : token, provider: provider)
        resolve(nil)
    }

    @objc public func referralsApplyCode(_ args: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        guard Self.requireConfigured(reject) else { return }
        guard let programId = args["programId"] as? String else { Self.invalid(reject, "programId is required", param: "programId"); return }
        guard let code = args["code"] as? String else { Self.invalid(reject, "code is required", param: "code"); return }
        Clikgate.shared.referrals.applyCode(programId: programId, code: code) { r in
            Self.complete(r, Self.map, resolve, reject, feature: Self.featureReferrals)
        }
    }

    @objc public func referralsReferredBy(_ args: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        guard Self.requireConfigured(reject) else { return }
        Clikgate.shared.referrals.referredBy { r in
            Self.complete(r, Self.map, resolve, reject, feature: Self.featureReferrals)
        }
    }

    // MARK: - v3 methods

    @objc public func isFeatureEnabled(_ args: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        guard let key = args["key"] as? String, !key.isEmpty else { resolve(false); return }
        // Before configure the SDK answers from the contract defaults.
        resolve(Clikgate.shared.isFeatureEnabled(key))
    }

    // MARK: - Engage features (internal)

    /// Request context for the Engage features (src/engage).
    @objc public func getRequestContext(_ args: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        guard Self.requireConfigured(reject) else { return }
        Self.run(nil, resolve, reject, Self.map) {
            try await Clikgate.shared.requestContext()
        }
    }

    @objc public func reportServerError(_ args: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        if let code = args["code"] as? String, !code.isEmpty {
            Clikgate.shared.reportServerError(code: code, feature: args["feature"] as? String)
        }
        resolve(nil)
    }

    // MARK: - Consent, Firebase, sales metadata (may be called before configure; the SDK keeps the values)

    private static let consentKeys = ["analytics", "attribution", "adUserData", "adPersonalization"]

    @objc public func setConsent(_ args: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        var states: [String: ClikgateConsentState] = [:]
        for key in Self.consentKeys {
            guard let raw = args[key], !(raw is NSNull) else { continue }
            guard let s = raw as? String, let state = ClikgateConsentState(rawValue: s) else {
                Self.invalid(reject, "\(key) must be granted, denied or unknown", param: key); return
            }
            states[key] = state
        }
        Clikgate.shared.setConsent(analytics: states["analytics"], attribution: states["attribution"],
                                   adUserData: states["adUserData"], adPersonalization: states["adPersonalization"])
        resolve(nil)
    }

    @objc public func getConsent(_ args: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        let c = Clikgate.shared.getConsent()
        resolve([
            "analytics": c.analytics.rawValue,
            "attribution": c.attribution.rawValue,
            "adUserData": c.adUserData.rawValue,
            "adPersonalization": c.adPersonalization.rawValue,
            "region": Self.nullable(c.region),
            "required": Self.nullable(c.isRequired),
        ] as [String: Any])
    }

    @objc public func setConsentRegion(_ args: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        let region = args["region"] as? String
        guard Clikgate.shared.setConsentRegionValidated(region) else {
            Self.invalid(reject, "region must be EEA, UK or an ISO 3166-1 alpha-2 country code", param: "region"); return
        }
        resolve(nil)
    }

    @objc public func enableFirebaseForwarding(_ args: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        Clikgate.shared.enableFirebaseForwarding(ClikgateFirebaseForwardingOptions(
            logAttributionEvent: (args["logAttributionEvent"] as? Bool) ?? true,
            setUserProperties: (args["setUserProperties"] as? Bool) ?? true))
        resolve(nil)
    }

    @objc public func attributionMetadata(_ args: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        resolve(Clikgate.shared.attributionMetadata())
    }

    @objc public func enableGoogleOnDeviceMeasurement(_ args: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        Clikgate.shared.enableGoogleOnDeviceMeasurement()
        resolve(nil)
    }

    static let featureReferrals = "referrals"
    static let featureDisabled = "feature_disabled"

    // MARK: - Result maps (camelCase, JSON-compatible values only)

    static func map(_ a: ClikgateAttribution) -> [String: Any] {
        [
            "status": a.status.rawValue,
            "matchType": nullable(a.matchType),
            "confidence": nullable(a.confidence),
            "clickId": nullable(a.clickId),
            "clickedAt": nullable(a.clickedAtRaw),
            "isReinstall": a.isReinstall,
            "installId": nullable(a.installId),
            "link": nullable(a.link.map(map)),
        ]
    }

    static func map(_ r: ClikgateDeepLinkResult) -> [String: Any] {
        [
            "url": nullable(r.url?.absoluteString),
            "path": nullable(r.path),
            "data": r.data,
            "isDeferred": r.isDeferred,
            "clickId": nullable(r.clickId),
            "matchType": nullable(r.matchType),
            "link": nullable(r.link.map(map)),
            "referral": nullable(r.referral.map(map)),
            "blockMessage": nullable(r.blockMessage),
        ]
    }

    static func map(_ l: ClikgateLink) -> [String: Any] {
        [
            "id": l.id,
            "kind": l.kind,
            "externalReference": nullable(l.externalReference),
            "campaignId": nullable(l.campaignId),
            "metadata": l.metadata,
        ]
    }

    static func map(_ r: ClikgateReferral) -> [String: Any] {
        [
            "referralId": r.referralId,
            "programId": r.programId,
            "status": r.status,
            "source": nullable(r.source),
            "referrerId": r.referrerId,
            "referrerDisplayName": nullable(r.referrerDisplayName),
            "createdAt": nullable(r.createdAtRaw),
        ]
    }

    static func map(_ b: ClikgateReferredBy) -> [String: Any] {
        ["referred": b.referred, "referral": nullable(b.referral.map(map))]
    }

    static func map(_ c: ClikgateRequestContext) -> [String: Any] {
        [
            "installationId": c.installationId, "sdkKey": c.sdkKey, "environment": c.environment,
            "apiBaseUrl": c.apiBaseUrl.absoluteString, "identityToken": nullable(c.identityToken),
            "customerUserId": nullable(c.customerUserId), "sdkVersion": c.sdkVersion,
            "nativeSdkVersion": nullable(c.nativeSdkVersion),
        ]
    }

    private static func nullable(_ v: Any?) -> Any { v ?? NSNull() }

    // MARK: - Errors

    /// `{status, param}` plus `feature` (feature_disabled) and `offlineTouchId` when set.
    static func errorInfo(status: Int?, param: String?, feature: String? = nil, offlineTouchId: String? = nil) -> [String: Any] {
        var info: [String: Any] = ["status": nullable(status), "param": nullable(param)]
        if let feature = feature { info["feature"] = feature }
        if let offlineTouchId = offlineTouchId { info["offlineTouchId"] = offlineTouchId }
        return info
    }

    /// `userInfo.feature` for `feature_disabled`: the SDK names the feature itself; the method's
    /// `feature` is the fallback. `userInfo.offlineTouchId` when the error carries one.
    static func reject(_ reject: Reject, _ e: ClikgateError, feature: String? = nil) {
        let f = e.code == featureDisabled ? (e.feature ?? feature) : nil
        reject(e.code, e.message, errorInfo(status: e.status, param: e.param, feature: f, offlineTouchId: e.offlineTouchId))
    }

    static func invalid(_ reject: Reject, _ message: String, param: String? = nil) {
        reject(ClikgateError.invalidArgument, message, errorInfo(status: nil, param: param))
    }

    private static func requireConfigured(_ reject: Reject) -> Bool {
        guard Clikgate.shared.isConfigured else {
            reject(ClikgateError.notConfigured, "Call Clikgate.configure first.", errorInfo(status: nil, param: nil))
            return false
        }
        return true
    }

    private static func complete<T>(_ r: Result<T, ClikgateError>, _ f: (T) -> [String: Any],
                                    _ resolve: Resolve, _ reject: Reject, feature: String? = nil) {
        switch r {
        case .success(let v): resolve(f(v))
        case .failure(let e): Self.reject(reject, e, feature: feature)
        }
    }

    /// Runs an async SDK call and settles the promise on the main actor.
    private static func run<T>(_ feature: String?, _ resolve: @escaping Resolve, _ reject: @escaping Reject,
                               _ f: @escaping (T) -> Any, _ work: @escaping () async throws -> T) {
        Task { @MainActor in
            do {
                resolve(f(try await work()))
            } catch let e as ClikgateError {
                Self.reject(reject, e, feature: feature)
            } catch {
                reject(ClikgateError.networkError, error.localizedDescription, errorInfo(status: nil, param: nil))
            }
        }
    }
}

/// One SDK deep-link handler for the process (the SDK supports a single handler). Survives
/// React Native reloads: the current module instance attaches itself. Links that arrive while no
/// JS listener is subscribed are buffered (latest 10) and flushed when JS starts observing.
/// The SDK calls back on the main actor; observer changes come from the module's method queue,
/// hence the lock.
final class DeepLinkHub {
    static let shared = DeepLinkHub()
    private static let capacity = 10

    private let lock = NSLock()
    private weak var module: ClikgateRNImpl?
    private var hasListeners = false
    private var buffer: [[String: Any]] = []
    private var installed = false

    func install() {
        lock.lock()
        let first = !installed
        installed = true
        lock.unlock()
        guard first else { return }
        Clikgate.shared.onDeepLink { [weak self] result in
            self?.dispatch(ClikgateRNImpl.map(result))
        }
        // Browser handoffs share the ClikgateDeepLink event, tagged.
        NotificationCenter.default.addObserver(forName: Clikgate.browserHandoffNotification, object: nil, queue: .main) { [weak self] n in
            guard let url = n.object as? URL else { return }
            self?.dispatch(["event": "browserHandoff", "url": url.absoluteString, "host": url.host?.lowercased() ?? ""])
        }
    }

    func attach(_ m: ClikgateRNImpl) {
        lock.lock()
        module = m
        hasListeners = false
        lock.unlock()
    }

    func detach(_ m: ClikgateRNImpl) {
        lock.lock()
        if module === m { module = nil; hasListeners = false }
        lock.unlock()
    }

    func setHasListeners(_ value: Bool, for m: ClikgateRNImpl) {
        lock.lock()
        guard module === m else { lock.unlock(); return }
        hasListeners = value
        let pending = value ? buffer : []
        if value { buffer = [] }
        lock.unlock()
        for e in pending { m.emit(e) }
    }

    private func dispatch(_ event: [String: Any]) {
        lock.lock()
        guard let m = module, hasListeners, m.emitter != nil else {
            buffer.append(event)
            if buffer.count > Self.capacity { buffer.removeFirst(buffer.count - Self.capacity) }
            lock.unlock()
            return
        }
        lock.unlock()
        m.emit(event)
    }
}
