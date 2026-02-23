require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "Neurosign"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "16.0" }
  s.source       = { :git => "https://github.com/po4erk91/react-native-neurosign.git", :tag => "#{s.version}" }

  s.source_files = "ios/**/*.{h,m,mm,swift}"
  s.private_header_files = "ios/**/*.h"
  s.swift_version = "5.9"

  s.frameworks   = "UIKit", "PencilKit", "PDFKit", "Security"
  s.prefix_header_contents = '#import <PencilKit/PencilKit.h>'

  # OpenSSL for CMS/PKCS#7 container construction (PAdES signing)
  s.dependency "OpenSSL-Universal", "~> 3.3"

  s.pod_target_xcconfig = {
    "CLANG_CXX_LANGUAGE_STANDARD" => "c++20",
    "GCC_PREPROCESSOR_DEFINITIONS" => "$(inherited)",
    "CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES" => "YES",
  }

  install_modules_dependencies(s)
end
