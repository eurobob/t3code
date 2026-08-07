Pod::Spec.new do |s|
  s.name           = 'T3Dictation'
  s.version        = '1.0.0'
  s.summary        = 'On-device push-to-talk dictation for T3 Code mobile.'
  s.description    = 'Live speech-to-text backed by SpeechAnalyzer on iOS 26+, falling back to SFSpeechRecognizer.'
  s.author         = 'T3 Tools'
  s.homepage       = 'https://t3tools.com'
  s.platforms      = {
    :ios => '18.0',
  }
  s.source         = { :path => '.' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }
  s.source_files = '**/*.{h,m,mm,swift,hpp,cpp}'
end
