// swift-tools-version:5.9
import PackageDescription

// claudewatch is a single-file macOS app (Cocoa + WebKit, system frameworks only).
// `swift run claudewatch` runs it in place; `./build.sh` packages the distributable .app.
let package = Package(
    name: "claudewatch",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "claudewatch", path: "Sources/claudewatch")
    ]
)
