import Foundation
import UIKit
@_spi(ClikgateWrapper) import Clikgate

/// App delegate helpers for React Native apps (which own their AppDelegate).
///
/// ```swift
/// import ClikgateReactNative
///
/// func application(_ app: UIApplication, open url: URL,
///                  options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
///   let clikgate = ClikgateRN.handle(url: url)
///   return RCTLinkingManager.application(app, open: url, options: options) || clikgate
/// }
///
/// func application(_ application: UIApplication, continue userActivity: NSUserActivity,
///                  restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
///   let clikgate = ClikgateRN.continue(userActivity: userActivity)
///   return RCTLinkingManager.application(application, continue: userActivity,
///                                        restorationHandler: restorationHandler) || clikgate
/// }
/// ```
///
/// Apps whose AppDelegate already forwards to `RCTLinkingManager` (the Expo template does) get
/// these links automatically: the module observes `RCTOpenURLNotification` from process start.
/// The same URL arriving through both paths within 2 seconds is handled once.
@objc(ClikgateRN)
public final class ClikgateRN: NSObject {
    static let wrapperName = "react-native"
    private static let duplicateWindow: TimeInterval = 2

    private static let lock = NSLock()
    private static var lastURL: String?
    private static var lastURLAt: Date = .distantPast
    private static var pendingPushToken: (token: String, provider: String)?

    /// Custom-scheme (and Universal Link) URLs. Returns true for Clikgate links once the SDK is
    /// configured; URLs received before `Clikgate.configure` (cold start) are kept by the SDK and
    /// handled right after it (this then returns false).
    @objc(handleURL:)
    @discardableResult
    public static func handle(url: URL) -> Bool {
        guard shouldHandle(url) else { return false }
        return Clikgate.shared.handle(url: url)
    }

    /// Universal Links (`NSUserActivityTypeBrowsingWeb`).
    @objc(continueUserActivity:)
    @discardableResult
    public static func `continue`(userActivity: NSUserActivity) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL else {
            return false
        }
        return handle(url: url)
    }

    /// Forward `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`. Returns true
    /// for Clikgate's silent uninstall checks, after calling `completionHandler(.noData)`; pass
    /// other notifications on to your own handling.
    @objc(handleRemoteNotification:completionHandler:)
    @discardableResult
    public static func handleRemoteNotification(_ userInfo: [AnyHashable: Any],
                                                completionHandler: @escaping (UIBackgroundFetchResult) -> Void) -> Bool {
        guard Clikgate.isClikgateMessage(userInfo) else { return false }
        completionHandler(.noData)
        return true
    }

    /// Pure check for Clikgate silent pushes (`cg.t == "uc"`), usable anywhere.
    @objc public static func isClikgateMessage(_ userInfo: [AnyHashable: Any]) -> Bool {
        Clikgate.isClikgateMessage(userInfo)
    }

    /// APNs device token from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`,
    /// for apps that don't use FCM. Kept until `Clikgate.configure` runs in JS when it arrives
    /// earlier (the native SDK drops tokens set before configure).
    @objc(setPushTokenWithDeviceToken:)
    public static func setPushToken(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        setPushToken(hex, provider: "apns")
    }

    /// FCM registration token (apps using Firebase Messaging natively on iOS).
    @objc(setPushTokenWithFcmToken:)
    public static func setPushToken(fcmToken: String) {
        setPushToken(fcmToken, provider: "fcm")
    }

    private static func setPushToken(_ token: String, provider: String) {
        guard !token.isEmpty else { return }
        lock.lock()
        let configured = Clikgate.shared.isConfigured
        if !configured { pendingPushToken = (token, provider) }
        lock.unlock()
        if configured { Clikgate.shared.setPushToken(token, provider: provider) }
    }

    /// Called by the module right after `Clikgate.configure`.
    static func didConfigure() {
        lock.lock()
        let pending = pendingPushToken
        pendingPushToken = nil
        lock.unlock()
        if let p = pending { Clikgate.shared.setPushToken(p.token, provider: p.provider) }
    }

    /// Called for `RCTOpenURLNotification` (posted by `RCTLinkingManager`).
    @objc public static func handleLinkingNotificationURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        handle(url: url)
    }

    private static func shouldHandle(_ url: URL) -> Bool {
        let s = url.absoluteString
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        if s == lastURL, now.timeIntervalSince(lastURLAt) < duplicateWindow { return false }
        lastURL = s
        lastURLAt = now
        return true
    }
}
