#
# iOS side of the clikgate_engage plugin: share.link / share.referralLink over the native Engage
# add-on (pod `Clikgate/Engage`). Everything else in clikgate_engage is Dart.
#
# Inside the monorepo the example app's Podfile points `Clikgate` at ../../../ios (local path).
# Published apps get `Clikgate/Engage` from CocoaPods trunk at the version below.
#
Pod::Spec.new do |s|
  s.name             = 'clikgate_engage'
  s.version          = '1.0.0'
  s.summary          = 'Clikgate Engage share helpers for Flutter (iOS).'
  s.description      = <<-DESC
Flutter plugin for the Clikgate Engage add-on's share menu: each app gets its own version of the
link and the share is recorded.
                       DESC
  s.homepage         = 'https://clikgate.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Clikgate' => 'sdk@clikgate.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'clikgate_engage/Sources/clikgate_engage/**/*.swift'
  s.dependency 'Flutter'
  s.dependency 'Clikgate/Engage', '~> 1.5.0'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'
end
