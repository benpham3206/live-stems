// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "LiveStems", platforms: [.macOS("14.2")], products: [.executable(name: "LiveStems", targets: ["LiveStems"])], targets: [
    .target(name: "AudioCore", linkerSettings: [.linkedFramework("CoreAudio")]),
    .executableTarget(name: "LiveStems", dependencies: ["AudioCore"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("AVFoundation"), .linkedFramework("CoreAudio")])
], swiftLanguageModes: [.v5])
