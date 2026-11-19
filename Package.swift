// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fosco",
    // 15.4 brought the pasteboard access setting the clipboard guard has to respect.
    platforms: [.macOS("15.4")],
    targets: [
        .target(name: "FoscoCore"),
        .executableTarget(name: "Fosco", dependencies: ["FoscoCore"]),
        .testTarget(name: "FoscoCoreTests", dependencies: ["FoscoCore"], resources: [.copy("Fixtures")]),
    ]
)
