// swift-tools-version: 6.0
import PackageDescription

// A small, dependency-free test harness for the SCELE integration. The app is built with Xcode.
let package = Package(
    name: "SCELEIntegrationChecks",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SCELECore", path: "boringNotch/components/SCELE/Core"),
        .testTarget(name: "SCELECoreTests", dependencies: ["SCELECore"], path: "Tests/SCELECoreTests")
    ],
    swiftLanguageModes: [.v5]
)
