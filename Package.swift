// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "LiveStems", platforms: [.macOS("14.2")], products: [.executable(name: "LiveStems", targets: ["LiveStems"])], targets: [
    .target(name: "AudioCore", linkerSettings: [.linkedFramework("CoreAudio")]),
    .target(name: "PitchCore", sources: ["PitchCore.cpp", "RubberBand.cpp",
        "vendor/libsamplerate-0.2.2/src/samplerate.c", "vendor/libsamplerate-0.2.2/src/src_sinc.c",
        "vendor/libsamplerate-0.2.2/src/src_linear.c", "vendor/libsamplerate-0.2.2/src/src_zoh.c"],
      publicHeadersPath: "include", cSettings: [.define("HAVE_CONFIG_H"),
        .headerSearchPath("vendor/libsamplerate-0.2.2/src"), .headerSearchPath("vendor/libsamplerate-0.2.2/include")],
      cxxSettings: [.headerSearchPath("vendor/libsamplerate-0.2.2/include")],
      linkerSettings: [.linkedFramework("Accelerate")]),
    .executableTarget(name: "LiveStems", dependencies: ["AudioCore", "PitchCore"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("AVFoundation"), .linkedFramework("CoreAudio")])
], swiftLanguageModes: [.v5], cxxLanguageStandard: .cxx17)
