# SPDX-License-Identifier: GPL-3.0-or-later
Pod::Spec.new do |s|
  s.name = 'venera_native'
  s.version = '1.0.0'
  s.summary = 'Audited native PNG and 7z codecs for VeneraNext.'
  s.homepage = 'https://github.com/CyrilPeng/Venera-Next'
  s.license = { :type => 'GPL-3.0-or-later', :file => 'LICENSE' }
  s.author = { 'VeneraNext contributors' => 'https://github.com/CyrilPeng/Venera-Next' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.{c,cpp}'
  s.resources = 'Resources/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) VENERA_LZMA_PORTABLE_ENDIAN=1',
    'HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/../third_party/lzma"',
    'GCC_SYMBOLS_PRIVATE_EXTERN' => 'YES'
  }
end
