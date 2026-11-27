#
# CocoaPods fallback for the steadfast downloader's iOS side; Swift Package
# Manager uses steadfast_downloader/Package.swift.
#
Pod::Spec.new do |s|
  s.name             = 'steadfast_downloader'
  s.version          = '0.1.0'
  s.summary          = 'Keeps downloads running while the app is in the background.'
  s.description      = <<-DESC
The iOS keep-alive of the steadfast downloader: a silent, mixable audio
session held while downloads wait or run.
                       DESC
  s.homepage         = 'https://kiritex.com'
  s.license          = { :type => 'MPL-2.0', :file => '../LICENSE' }
  s.author           = 'Kiritex'
  s.source           = { :path => '.' }
  s.source_files = 'steadfast_downloader/Sources/steadfast_downloader/**/*.swift'
  s.dependency 'Flutter'
  s.resource_bundles = { 'steadfast_downloader_privacy' => ['steadfast_downloader/Sources/steadfast_downloader/PrivacyInfo.xcprivacy'] }
  s.frameworks = 'AVFoundation', 'UserNotifications'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
