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
        .target(name: "VibekeyCore", linkerSettings: [
            .linkedFramework("IOKit"), .linkedFramework("CoreAudio"), .linkedFramework("Carbon")
        ]),
        .executableTarget(name: "Vibekey", dependencies: ["VibekeyCore"]),
        .executableTarget(name: "VibekeyProbe", dependencies: ["VibekeyCore"]),
        .testTarget(name: "VibekeyCoreTests", dependencies: ["VibekeyCore"])
    ]
)
