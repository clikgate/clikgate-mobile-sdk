import Flutter
import UIKit
@_spi(ClikgateWrapper) @_spi(ClikgateEngage) import Clikgate

/// iOS side of `clikgate_flutter`: implements the platform channel over the native Clikgate SDK.
/// No attribution or referral logic lives here.
public final class ClikgateFlutterPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    static let methodChannelName = "com.clikgate/sdk"
    static let eventChannelName = "com.clikgate/deep_links"
    static let bufferLimit = 10

    private var eventSink: FlutterEventSink?
    /// Deep links that arrived before Dart listened (latest 10).
    private var pendingEvents: [[String: Any]] = []

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = ClikgateFlutterPlugin()
        let methods = FlutterMethodChannel(name: methodChannelName, binaryMessenger: registrar.messenger())
        let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: methods)
        events.setStreamHandler(instance)
        registrar.addApplicationDelegate(instance)
        registrar.publish(instance)
        // Receive every deep link (the SDK buffers until a handler exists, then hands them over).
        Clikgate.shared.onDeepLink { [weak instance] result in
            instance?.emit(Self.map(result))
        }
        // Browser handoffs share the event channel, tagged.
        NotificationCenter.default.addObserver(forName: Clikgate.browserHandoffNotification, object: nil, queue: .main) { [weak instance] n in
            guard let url = n.object as? URL else { return }
            instance?.emit(["event": "browserHandoff", "url": url.absoluteString, "host": url.host?.lowercased() ?? ""])
        }
    }

    // MARK: - EventChannel

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        let pending = pendingEvents
        pendingEvents = []
        for e in pending { events(e) }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    private func emit(_ event: [String: Any]) {
        if let sink = eventSink {
            sink(event)
        } else {
            pendingEvents.append(event)
            if pendingEvents.count > Self.bufferLimit { pendingEvents.removeFirst(pendingEvents.count - Self.bufferLimit) }
        }
    }

    // MARK: - MethodChannel

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = (call.arguments as? [String: Any]) ?? [:]
        let sdk = Clikgate.shared

        switch call.method {
        case "configure":
            configure(args, result: result)
            return
        case "sdkVersion":
            result(Clikgate.sdkVersion)
            return
        case "handleUrl":
            guard let s = args["url"] as? String, let url = URL(string: s) else {
                result(Self.invalidArgument("url must be a valid URL string")); return
            }
            result(sdk.handle(url: url))
            return
        case "isFeatureEnabled":
            // Answers before configure too (catalogue defaults).
            guard let key = args["key"] as? String else { result(Self.invalidArgument("key is required", param: "key")); return }
            result(sdk.isFeatureEnabled(key))
            return
        // ---- consent, Firebase, sales metadata: these work before configure too (the SDK keeps them until configure).
        case "setConsent":
            var states: [ClikgateConsentState?] = []
            for key in ["analytics", "attribution", "adUserData", "adPersonalization"] {
                guard let raw = args[key] as? String else { states.append(nil); continue }
                guard let state = ClikgateConsentState(rawValue: raw) else {
                    result(Self.invalidArgument("\(key) must be granted, denied or unknown", param: key)); return
                }
                states.append(state)
            }
            sdk.setConsent(analytics: states[0], attribution: states[1], adUserData: states[2], adPersonalization: states[3])
            result(nil)
            return
        case "getConsent":
            let c = sdk.getConsent()
            result([
                "analytics": c.analytics.rawValue, "attribution": c.attribution.rawValue,
                "adUserData": c.adUserData.rawValue, "adPersonalization": c.adPersonalization.rawValue,
                "region": c.region as Any, "required": c.isRequired as Any,
            ])
            return
        case "setConsentRegion":
            let region = args["region"] as? String
            guard sdk.setConsentRegionValidated(region) else {
                result(Self.invalidArgument("region must be EEA, UK or an ISO 3166-1 alpha-2 country code", param: "region")); return
            }
            result(nil)
            return
        case "enableFirebaseForwarding":
            let map = (args["eventNameMap"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            sdk.enableFirebaseForwarding(ClikgateFirebaseForwardingOptions(
                logAttributionEvent: args["logAttributionEvent"] as? Bool ?? true,
                setUserProperties: args["setUserProperties"] as? Bool ?? true,
                mirrorEvents: args["mirrorEvents"] as? Bool ?? false,
                eventNameMap: map))
            result(nil)
            return
        case "attributionMetadata":
            result(sdk.attributionMetadata())
            return
        case "enableGoogleOnDeviceMeasurement":
            sdk.enableGoogleOnDeviceMeasurement()
            result(nil)
            return
        default:
            break
        }

        guard sdk.isConfigured else {
            result(FlutterError(code: ClikgateError.notConfigured, message: "Call Clikgate.configure first.",
                                details: Self.details(status: nil, param: nil)))
            return
        }

        switch call.method {
        case "getAttribution":
            sdk.attribution { r in
                switch r {
                case .success(let a): result(Self.map(a))
                case .failure(let e): result(Self.flutterError(e))
                }
            }

        case "track":
            guard let name = args["name"] as? String else { result(Self.invalidArgument("name is required", param: "name")); return }
            var revenue: ClikgateMoney?
            let amount = (args["revenueMinor"] as? NSNumber)?.int64Value
            let currency = args["currency"] as? String
            switch (amount, currency) {
            case let (a?, c?): revenue = ClikgateMoney.ofMinor(a, currency: c)
            case (nil, nil): revenue = nil
            default:
                result(Self.invalidArgument("revenueMinor and currency go together", param: "currency")); return
            }
            let properties = args["properties"] as? [String: Any]
            sdk.track(name, revenue: revenue, properties: properties) { error in
                result(error.map(Self.flutterError))
            }

        case "goal":   // the value arrives as a decimal string; answers with the goal's result
            guard let key = args["key"] as? String else { result(Self.invalidArgument("key is required", param: "goal")); return }
            sdk.goal(key, decimalString: args["value"] as? String, currency: args["currency"] as? String,
                     reference: args["reference"] as? String, providerKey: args["provider"] as? String,
                     isFirst: args["isFirst"] as? Bool, label: args["label"] as? String) { r in
                result(["status": "\(r.status)", "reason": Self.nullable(r.reason), "goalKind": Self.nullable(r.goalKind.map { "\($0)" }),
                        "valueIgnored": r.valueIgnored])
            }

        case "identifyUser":   // "customerId" absent keeps the stored one; null clears it
            let label = args["label"] as? String, token = args["identityToken"] as? String
            if args.keys.contains("customerId") {
                sdk.identifyUser(label: label, customerId: args["customerId"] as? String, identityToken: token)
            } else {
                sdk.identifyUser(label: label, identityToken: token)
            }
            result(nil)

        case "setTrackingEnabled":
            guard let enabled = args["enabled"] as? Bool else { result(Self.invalidArgument("enabled is required", param: "enabled")); return }
            sdk.setTrackingEnabled(enabled)
            result(nil)

        case "setPushToken":
            guard let token = args["token"] as? String, !token.isEmpty else {
                result(Self.invalidArgument("token is required", param: "token")); return
            }
            let provider = (args["provider"] as? String) ?? "fcm"
            guard provider == "fcm" || provider == "apns" else {
                result(Self.invalidArgument("provider must be fcm or apns", param: "provider")); return
            }
            sdk.setPushToken(provider == "apns" ? token.lowercased() : token, provider: provider)
            result(nil)

        case "referrals.applyCode":
            guard let programId = args["programId"] as? String else { result(Self.invalidArgument("programId is required", param: "programId")); return }
            guard let code = args["code"] as? String else { result(Self.invalidArgument("code is required", param: "code")); return }
            sdk.referrals.applyCode(programId: programId, code: code) { r in
                result(Self.unwrap(r, Self.map))
            }

        case "referrals.referredBy":
            sdk.referrals.referredBy { r in
                result(Self.unwrap(r, Self.map))
            }

        // ---- Engage add-on support (internal): clikgate_engage calls /v1/sdk/* itself
        case "getRequestContext":
            Task {
                do {
                    let c = try await sdk.requestContext()
                    let m = Self.map(c)
                    await MainActor.run { result(m) }
                } catch let e as ClikgateError {
                    let fe = Self.flutterError(e)
                    await MainActor.run { result(fe) }
                } catch {
                    let fe = FlutterError(code: ClikgateError.networkError, message: error.localizedDescription,
                                          details: Self.details(status: nil, param: nil))
                    await MainActor.run { result(fe) }
                }
            }

        case "reportServerError":
            guard let code = args["code"] as? String else { result(Self.invalidArgument("code is required", param: "code")); return }
            sdk.reportServerError(code: code, feature: args["feature"] as? String)
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func configure(_ args: [String: Any], result: FlutterResult) {
        guard let sdkKey = args["sdkKey"] as? String, sdkKey.hasPrefix("cg_sdk_") else {
            result(Self.invalidArgument("sdkKey must be a Clikgate SDK key (cg_sdk_...)", param: "sdkKey")); return
        }
        if Clikgate.shared.isConfigured { result(nil); return }   // hot restart: native SDK keeps running

        var options = ClikgateOptions()
        options.linkDomains = (args["linkDomains"] as? [String]) ?? []
        if let base = args["apiBaseUrl"] as? String, !base.isEmpty {
            guard let url = URL(string: base), url.scheme != nil else {
                result(Self.invalidArgument("apiBaseUrl must be an absolute URL", param: "apiBaseUrl")); return
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
        case "off": options.pasteboardMode = .off
        case "pasteControlOnly": options.pasteboardMode = .pasteControlOnly
        case "automatic": options.pasteboardMode = .automatic
        default: options.pasteboardMode = .off   // opt-in since 1.2.0
        }
        options.waitForATT = (args["waitForATT"] as? Bool) ?? false
        if let ms = (args["deferredDeepLinkTimeoutMs"] as? NSNumber)?.doubleValue, ms >= 0 {
            options.deferredDeepLinkTimeout = ms / 1000
        }
        options.platformDomainBrowserFallback = (args["platformDomainBrowserFallback"] as? Bool) ?? true
        Clikgate.setWrapper(name: "flutter", version: (args["wrapperVersion"] as? String) ?? "0.0.0")
        Clikgate.configure(sdkKey: sdkKey, options: options)
        result(nil)
    }

    // MARK: - Application delegate forwarding

    public func application(_ application: UIApplication, open url: URL,
                            options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        Clikgate.shared.handle(url: url)
    }

    public func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                            restorationHandler: @escaping ([Any]) -> Void) -> Bool {
        Clikgate.shared.continue(userActivity: userActivity)
    }

    public func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                            fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) -> Bool {
        guard Clikgate.shared.handleRemoteNotification(userInfo) else { return false }   // let other plugins handle it
        completionHandler(.noData)
        return true
    }

    /// Opt-in (Info.plist `ClikgateForwardAPNsToken` = YES): register the raw APNs token for apps that
    /// don't use FCM. Apps using firebase_messaging should call `Clikgate.setPushToken(fcmToken)` from Dart instead.
    public func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard (Bundle.main.object(forInfoDictionaryKey: "ClikgateForwardAPNsToken") as? Bool) == true,
              Clikgate.shared.isConfigured else { return }
        Clikgate.shared.setPushToken(deviceToken: deviceToken)
    }

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

    static func details(status: Int?, param: String?) -> [String: Any] {
        ["status": nullable(status), "param": nullable(param)]
    }

    /// `{status, param}` plus `feature` (feature_disabled) and `offlineTouchId` (codes.redeem) when set.
    static func flutterError(_ e: ClikgateError) -> FlutterError {
        var d = details(status: e.status, param: e.param)
        if let f = e.feature { d["feature"] = f }
        if let t = e.offlineTouchId { d["offlineTouchId"] = t }
        return FlutterError(code: e.code, message: e.message, details: d)
    }

    static func invalidArgument(_ message: String, param: String? = nil) -> FlutterError {
        FlutterError(code: ClikgateError.invalidArgument, message: message, details: details(status: nil, param: param))
    }

    private static func unwrap<T>(_ r: Result<T, ClikgateError>, _ f: (T) -> [String: Any]) -> Any {
        switch r {
        case .success(let v): return f(v)
        case .failure(let e): return flutterError(e)
        }
    }
}
