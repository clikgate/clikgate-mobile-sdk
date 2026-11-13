#
# iOS side of the clikgate_flutter plugin: a bridge over the native Clikgate SDK (pod `Clikgate`).
#
# Inside the monorepo the example app's Podfile points `Clikgate` at ../../../ios (local path).
# Published apps get `Clikgate` from CocoaPods trunk at the version below.
#
Pod::Spec.new do |s|
  s.name             = 'clikgate_flutter'
  s.version          = '2.1.0'
  s.summary          = 'Clikgate deep linking, install attribution, referrals and uninstall tracking for Flutter (iOS).'
  s.description      = <<-DESC
Flutter plugin bridging to the Clikgate iOS SDK: Universal Links, deferred deep links,
attribution, events, referrals and push-token registration for uninstall tracking.
                       DESC
  s.homepage         = 'https://clikgate.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Clikgate' => 'sdk@clikgate.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'clikgate_flutter/Sources/clikgate_flutter/**/*.swift'
  s.resource_bundles = { 'clikgate_flutter_privacy' => ['clikgate_flutter/Sources/clikgate_flutter/PrivacyInfo.xcprivacy'] }
  s.dependency 'Flutter'
  s.dependency 'Clikgate', '~> 2.1.0'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'
end
