import UIKit
import React
import React_RCTAppDelegate
import ReactAppDependencyProvider
import ClikgateReactNative

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  var reactNativeDelegate: ReactNativeDelegate?
  var reactNativeFactory: RCTReactNativeFactory?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    let delegate = ReactNativeDelegate()
    let factory = RCTReactNativeFactory(delegate: delegate)
    delegate.dependencyProvider = RCTAppDependencyProvider()

    reactNativeDelegate = delegate
    reactNativeFactory = factory

    window = UIWindow(frame: UIScreen.main.bounds)

    factory.startReactNative(
      withModuleName: "ClikgateExample",
      in: window,
      launchOptions: launchOptions
    )

    // Uninstall tracking: the SDK registers for remote notifications itself (automaticPushToken,
    // default on) when it's on in the dashboard; no permission prompt. The token arrives below.
    return true
  }

  // MARK: - Clikgate deep links (custom scheme + Universal Links)
  // ClikgateRN hands the URL to the Clikgate SDK (kept until Clikgate.configure runs in JS);
  // RCTLinkingManager keeps React Native's Linking API working. The same URL reaching Clikgate
  // through both is handled once.

  func application(
    _ app: UIApplication, open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    let clikgate = ClikgateRN.handle(url: url)
    return RCTLinkingManager.application(app, open: url, options: options) || clikgate
  }

  func application(
    _ application: UIApplication, continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    let clikgate = ClikgateRN.continue(userActivity: userActivity)
    return RCTLinkingManager.application(
      application, continue: userActivity, restorationHandler: restorationHandler) || clikgate
  }

  // MARK: - Push (APNs) for uninstall tracking

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    // The one line uninstall tracking needs. A token passed from JS with Clikgate.setPushToken wins.
    ClikgateRN.setPushToken(deviceToken: deviceToken)
  }

  func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    if ClikgateRN.handleRemoteNotification(userInfo, completionHandler: completionHandler) { return }
    completionHandler(.noData)  // the app's own handling goes here
  }
}

class ReactNativeDelegate: RCTDefaultReactNativeFactoryDelegate {
  override func sourceURL(for bridge: RCTBridge) -> URL? {
    self.bundleURL()
  }

  override func bundleURL() -> URL? {
#if DEBUG
    RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
#else
    Bundle.main.url(forResource: "main", withExtension: "jsbundle")
#endif
  }
}
