Pod::Spec.new do |s|
  s.name             = 'Clikgate'
  s.version          = '1.5.1'
  s.summary          = 'Clikgate iOS SDK: deep links, deferred deep links, install attribution, referrals and uninstall tracking.'
  s.description      = <<-DESC
    The Clikgate SDK handles Universal Links and custom-scheme links, deferred deep links
    (pasteboard / Apple Search Ads), install attribution, goals, referral codes (referee side),
    push-token registration for uninstall tracking and SKAdNetwork / AdAttributionKit conversion
    values. No third-party dependencies.
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

  # Core is the default subspec: `pod 'Clikgate'` installs the core SDK only. The optional Engage
  # add-on (spec 17A) is `pod 'Clikgate/Engage'`, which depends on Core and never the other way round.
  s.default_subspec  = 'Core'

  # Paths are relative to ios/ (the podspec's directory, and the root of the release zip).
  s.subspec 'Core' do |core|
    core.source_files     = 'Sources/Clikgate/**/*.swift'
    core.resource_bundles = { 'Clikgate_Privacy' => ['Sources/Clikgate/Resources/PrivacyInfo.xcprivacy'] }
    core.frameworks       = 'Foundation', 'UIKit', 'Security', 'StoreKit', 'CryptoKit', 'SafariServices'
    core.weak_frameworks  = 'AdServices', 'AdAttributionKit', 'AppTrackingTransparency', 'DeviceCheck'
  end

  # CocoaPods compiles all subspecs into the single `Clikgate` module (SPM has a separate
  # `ClikgateEngage` module). The condition below makes the Engage sources skip their
  # `import Clikgate` in that case; app code uses `import Clikgate` with CocoaPods.
  s.subspec 'Engage' do |engage|
    engage.dependency 'Clikgate/Core'
    engage.source_files = 'Sources/ClikgateEngage/**/*.swift'
    engage.frameworks   = 'Foundation', 'UIKit'
    engage.pod_target_xcconfig = { 'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => '$(inherited) CLIKGATE_POD_SINGLE_MODULE' }
  end

  # Release builds of the pod optimise for size (budgets: core < 410 KB, Engage < 80 KB).
  s.pod_target_xcconfig = { 'SWIFT_OPTIMIZATION_LEVEL[config=Release]' => '-Osize' }
end
