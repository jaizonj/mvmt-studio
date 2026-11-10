require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

Pod::Spec.new do |s|
  s.name           = 'MvmtWhisper'
  s.version        = package['version']
  s.summary        = package['description']
  s.description    = package['description']
  s.license        = package['license']
  s.author         = 'MVMT Studio'
  s.homepage       = 'https://expo.dev'
  s.platforms      = {
    :ios => '15.5'
  }
  s.swift_version  = '5.9'
  s.source         = { git: 'https://expo.dev' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  # Only this module's own sources. Deliberately NOT a recursive glob:
  # the vendored whisper.xcframework below ships its own C headers
  # (whisper.h, ggml*.h) which must never be swept into this pod's
  # source list — they arrive through the framework's module map.
  s.source_files = "*.{h,m,swift}"

  # whisper.cpp + ggml, prebuilt by the ggml-org CI (release b5454,
  # matching whisper.cpp v1.9.5), trimmed to the iOS device + simulator
  # slices. See ../INTEGRATION.md for provenance and the decision
  # record that chose this over WhisperKit.
  s.vendored_frameworks = 'whisper.xcframework'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES'
  }
end
