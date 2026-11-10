# clikgate_flutter — iOS setup

The plugin's iOS side wraps the native Clikgate iOS SDK. It registers itself as an application delegate
and forwards:

| Delegate method | Forwarded to |
|---|---|
| `application(_:open:options:)` (custom schemes) | `handle(url:)` |
| `application(_:continue:restorationHandler:)` (Universal Links) | `continue(userActivity:)` |
| `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` | `handleRemoteNotification`: Clikgate's silent uninstall checks are answered with `.noData` and not passed on; every other push goes to the other plugins (e.g. `firebase_messaging`) |

Links that open the app before Dart calls `Clikgate.configure` are kept and handled right after it.

Requirements:
- Xcode 26 or newer.
- iOS 13 for the plugin. Firebase (`firebase_messaging` 16) needs iOS 15.
- CocoaPods (default) or Swift Package Manager (`flutter config --enable-swift-package-manager`).

## 1. Podfile

Nothing to add: `clikgate_flutter.podspec` depends on the `Clikgate` pod (`~> 2.0.0`) from CocoaPods
trunk. Set the platform to at least what your other plugins need:

```ruby
platform :ios, '15.0'   # 13.0 is enough for Clikgate alone
```

Developing against a local checkout of the SDK (as `flutter/example` does in this repository):

```ruby
target 'Runner' do
  use_frameworks!
  pod 'Clikgate', :path => '../../../ios'   # path to clikgate-mobile-sdk/ios
  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))
end
```

With Swift Package Manager enabled, the plugin's `ios/clikgate_flutter/Package.swift` depends on
`https://github.com/clikgate/clikgate-ios-sdk` (or on `../../../ios` inside the monorepo).

## 2. Associated Domains (Universal Links)

In `ios/Runner.xcworkspace` go to **Runner → Signing & Capabilities → + Capability → Associated Domains**
and add `applinks:inv.myapp.com` (one per Clikgate link domain). This creates `Runner/Runner.entitlements`:

```xml
<key>com.apple.developer.associated-domains</key>
<array>
    <string>applinks:inv.myapp.com</string>
</array>
```

Add **every** domain of your Clikgate domain group (aliases such as `ybr.ng` and `go.yourbrand.com`
serve the same links): one `applinks:<domain>` entry each. Pass the same domains to
`Clikgate.configure(linkDomains: [...])`. Clikgate serves `apple-app-site-association` and `assetlinks.json` on every active domain of the group, but the OS opens your app only for the domains the app itself declares. The SDK also adds the domains the server lists in `/v1/sdk/config` (`link_domains`, cached with the config, compared case-insensitively) and logs a warning naming each server domain missing from `linkDomains`: add it to `linkDomains` and to Associated Domains. The example app keeps the domain in
`ios/Flutter/Clikgate.xcconfig` (`CLIKGATE_LINK_DOMAIN`) and uses `applinks:$(CLIKGATE_LINK_DOMAIN)`.

## 3. URL scheme (interstitial "Open in app")

Add to `ios/Runner/Info.plist` (or use **Info → URL Types**):

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array><string>myapp</string></array>
    </dict>
</array>
```

## 4. Push (uninstall tracking)

1. **Signing & Capabilities → + Push Notifications**, and **+ Background Modes → Remote notifications**
   (`UIBackgroundModes` = `remote-notification`). Silent pushes don't need the notification permission prompt.
2. **With `firebase_messaging`** (recommended):
   - send the FCM token from Dart: `Clikgate.setPushToken(token, provider: PushProvider.fcm)`;
   - in your handlers, `if (Clikgate.isClikgateMessage(message.data)) return;`.

   Clikgate sends FCM data `{"cg":"uc"}` with `content-available`.
3. **Native APNs without FCM**: either pass the hex APNs token from Dart with
   `provider: PushProvider.apns`, or let the plugin forward it by adding to `Info.plist`:

```xml
<key>ClikgateForwardAPNsToken</key>
<true/>
```

   It is off by default, so apps that use FCM don't register two tokens. Call
   `UIApplication.shared.registerForRemoteNotifications()` in your AppDelegate (or let
   `firebase_messaging` do it).

## 5. Scenes

Flutter 3.35 apps use `FlutterAppDelegate` without scenes, so nothing more is needed. If your app adopts
`UISceneDelegate`, forward the scene callbacks yourself:

```swift
import Clikgate

class SceneDelegate: FlutterSceneDelegate {   // FlutterSceneDelegate (3.35) doesn't implement these
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        connectionOptions.userActivities.forEach { _ = Clikgate.shared.continue(userActivity: $0) }
        connectionOptions.urlContexts.forEach { _ = Clikgate.shared.handle(url: $0.url) }
    }
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        Clikgate.shared.continue(userActivity: userActivity)
    }
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        URLContexts.forEach { Clikgate.shared.handle(url: $0.url) }
    }
}
```

(`import Clikgate` works in Runner because the plugin's pod depends on it.)

## 6. iOS-only options

```dart
await Clikgate.configure(
  sdkKey: 'cg_sdk_...',
  linkDomains: ['inv.myapp.com'],
  pasteboardMode: ClikgatePasteboardMode.automatic,  // off | automatic | pasteControlOnly
  waitForATT: false,      // wait up to 30 s for your own ATT prompt before the first install call
);
```

`automatic` reads the pasteboard once, on the first launch, and only when a web URL is likely; iOS 16+
shows the "Allow Paste" prompt. `pasteControlOnly` avoids the prompt, but needs the native
`ClikgatePasteControl` button, which Flutter has no widget for yet. Leave it on `automatic` unless you add a
platform view.

### WhatsApp sharing

`ClikgateEngage().share.whatsApp` (package `clikgate_engage`) opens `whatsapp://send?text=…` with
`url_launcher`, which calls `UIApplication.open` without a `canOpenURL` check, so it works without an
Info.plist entry; when WhatsApp isn't installed the system share sheet is shown and the call returns
`false`. Listing the scheme is still recommended (the native `ClikgateEngage` iOS module checks
`canOpenURL`, which answers only for listed schemes):

```xml
<key>LSApplicationQueriesSchemes</key>
<array>
    <string>whatsapp</string>
</array>
```

## 7. Local backend and simulators

- To reach `http://localhost:8000` from a debug build, allow local networking in `Info.plist`:

```xml
<key>NSAppTransportSecurity</key>
<dict><key>NSAllowsLocalNetworking</key><true/></dict>
```

- `flutter build ios --simulator --no-codesign` builds are unsigned and have no Keychain access, so reinstall
  detection only works in signed builds (`flutter run` signs simulator builds automatically).
- The simulator asks "Open in …?" for custom-scheme links: `xcrun simctl openurl booted 'myapp://p?cg_click_id=clk_test'`.
- Universal Links need the AASA file on a real domain. See [TESTING_DEEP_LINKS.md](TESTING_DEEP_LINKS.md).

## 8. Releasing

The published plugin's podspec depends on `Clikgate ~> 2.0.0` from trunk, so release the iOS SDK
(`ios-v<version>` tag → CocoaPods trunk + SPM mirror) **before** publishing a plugin version that needs it.
