import UIKit
import Clikgate

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let main = MainViewController()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let sdkKey = info["ClikgateSDKKey"] as? String ?? ""
        let domain = info["ClikgateLinkDomain"] as? String ?? ""
        var options = ClikgateOptions(linkDomains: domain.isEmpty ? [] : [domain], logLevel: .debug,
                                      environment: .sandbox, pasteboardMode: .automatic)   // opt-in clipboard deferred link
        if let base = (info["ClikgateApiBaseUrl"] as? String).flatMap(URL.init(string:)) {
            options.apiBaseUrl = base
        }
        // Forward Clikgate attribution to Firebase Analytics when the app links Firebase
        // (detected at runtime; the sample doesn't), and pass Google's on-device measurement info
        // when GoogleAdsOnDeviceConversion is linked. Both may be called before configure.
        Clikgate.shared.enableFirebaseForwarding(ClikgateFirebaseForwardingOptions())
        Clikgate.shared.enableGoogleOnDeviceMeasurement()
        Clikgate.configure(sdkKey: sdkKey, options: options)

        // One handler for deferred (first launch) and direct (Universal Link / scheme) deep links.
        Clikgate.shared.onDeepLink { [weak self] result in
            self?.main.show(deepLink: result)
        }

        // Silent pushes (uninstall checks) need only a device token, not notification permission.
        application.registerForRemoteNotifications()

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: main)
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    // Custom URL scheme (and the interstitial's "Open in app" button).
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        Clikgate.shared.handle(url: url)
    }

    // Universal Links.
    func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        Clikgate.shared.continue(userActivity: userActivity)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Clikgate.shared.setPushToken(deviceToken: deviceToken)
        main.pushStatus = "APNs token registered (\(deviceToken.count) bytes)"
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        main.pushStatus = "Push registration failed: \(error.localizedDescription)"
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        if Clikgate.shared.handleRemoteNotification(userInfo) {
            completionHandler(.noData)   // Clikgate uninstall check: nothing to show
            return
        }
        completionHandler(.noData)
    }
}
