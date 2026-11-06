require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

# iOS side of @clikgate/react-native: a TurboModule over the native Clikgate iOS SDK (pod
# `Clikgate`). Inside the monorepo the example's Podfile points `Clikgate` at ../../ios (local
# path); apps get it from CocoaPods trunk at the version below.
Pod::Spec.new do |s|
  s.name         = "clikgate-react-native"
  s.module_name  = "ClikgateReactNative"
  s.version      = package["version"]
  s.summary      = "Clikgate deep linking, install attribution, referrals and uninstall tracking for React Native (iOS)."
  s.homepage     = "https://clikgate.com"
  s.license      = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.authors      = { "Clikgate" => "sdk@clikgate.com" }

  s.platforms    = { :ios => min_ios_version_supported }
  s.source       = { :git => "https://github.com/clikgate/clikgate-mobile-sdk.git", :tag => "react-native-v#{s.version}" }

  s.source_files = "ios/**/*.{h,m,mm,swift}"
  s.private_header_files = "ios/**/*.h"
  s.swift_version = "5.9"

  s.dependency "Clikgate", "~> 1.5.1"

  install_modules_dependencies(s)
end
