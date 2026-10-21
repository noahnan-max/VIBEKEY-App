// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "Vibekey",
    platforms: [.macOS("13.3")],
    products: [
        .executable(name: "Vibekey", targets: ["Vibekey"]),
        .executable(name: "vibekey-probe", targets: ["VibekeyProbe"])
    ],
    targets: [
        .binaryTarget(name: "Sparkle", url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip", checksum: "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"),
        .target(name: "VibekeyCore", linkerSettings: [
            .linkedFramework("IOKit"), .linkedFramework("CoreAudio"), .linkedFramework("Carbon")
        ]),
        .executableTarget(name: "Vibekey", dependencies: ["VibekeyCore", "Sparkle"]),
        .executableTarget(name: "VibekeyProbe", dependencies: ["VibekeyCore"]),
        .testTarget(name: "VibekeyCoreTests", dependencies: ["VibekeyCore"])
    ]
)
