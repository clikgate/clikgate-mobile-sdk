Pod::Spec.new do |s|
  s.name             = 'Clikgate'
  s.version          = '2.1.0'
  s.summary          = 'Clikgate iOS SDK: deep links, deferred deep links, install attribution, referrals, uninstall tracking and Engage features.'
  s.description      = <<-DESC
    The Clikgate SDK handles Universal Links and custom-scheme links, deferred deep links
    (pasteboard / Apple Search Ads), install attribution, goals, referral codes (referee side),
    push-token registration for uninstall tracking and SKAdNetwork / AdAttributionKit conversion
    values, plus the Engage features for apps without their own backend (referral link and stats,
    leaderboards, promo codes, share helpers). No third-party dependencies.
  DESC
  s.homepage         = 'https://clikgate.com'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'Clikgate' => 'sdk@clikgate.com' }
  # The podspec lives in ios/ of the monorepo. With a :git source CocoaPods would resolve file
  # patterns from the repository root, so releases ship a zip of the ios/ directory instead
  # (built and attached to the `ios-v<version>` GitHub release by .github/workflows/ios.yml).
  s.source           = { :http => "https://github.com/clikgate/clikgate-mobile-sdk/releases/download/ios-v#{s.version}/Clikgate-ios-#{s.version}.zip" }

  s.ios.deployment_target = '13.0'
  s.swift_versions   = ['5.9', '5.10', '6.0']
  s.module_name      = 'Clikgate'
  s.static_framework = false

  # One pod (since 2.1.0): the core SDK and its Engage features. CocoaPods compiles both source folders into
  # the single `Clikgate` module (SPM keeps a separate `ClikgateEngage` module in the same product); the
  # condition below makes the Engage sources skip their `import Clikgate`. App code uses `import Clikgate`
  # with CocoaPods. Paths are relative to ios/ (the podspec's directory, and the root of the release zip).
  s.source_files     = 'Sources/Clikgate/**/*.swift', 'Sources/ClikgateEngage/**/*.swift'
  s.resource_bundles = { 'Clikgate_Privacy' => ['Sources/Clikgate/Resources/PrivacyInfo.xcprivacy'] }
  s.frameworks       = 'Foundation', 'UIKit', 'Security', 'StoreKit', 'CryptoKit', 'SafariServices'
  s.weak_frameworks  = 'AdServices', 'AdAttributionKit', 'AppTrackingTransparency', 'DeviceCheck'

  # Release builds of the pod optimise for size (budgets, measured per source folder: core < 410 KB, Engage < 95 KB).
  s.pod_target_xcconfig = {
    'SWIFT_OPTIMIZATION_LEVEL[config=Release]' => '-Osize',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => '$(inherited) CLIKGATE_POD_SINGLE_MODULE',
  }
end
