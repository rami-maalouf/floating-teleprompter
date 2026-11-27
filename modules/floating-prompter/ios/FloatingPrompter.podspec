Pod::Spec.new do |s|
  s.name           = 'FloatingPrompter'
  s.version        = '1.0.0'
  s.summary        = 'Scrolling script in a native Picture in Picture window'
  s.description    = 'Renders a script into video frames and shows them in a native Picture in Picture window'
  s.license        = 'MIT'
  s.author         = 'Rami Maalouf'
  s.homepage       = 'https://expo.dev'
  s.platforms      = { :ios => '16.4' }
  s.swift_version  = '5.9'
  s.source         = { git: 'https://github.com/expo/expo.git' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  s.source_files = "**/*.{h,m,swift}"
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule'
  }
end
