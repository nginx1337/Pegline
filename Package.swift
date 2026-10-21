// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Pegline",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "Pegline", targets: ["Pegline"])
    ],
    targets: [
        // Pure logic with no UI: layout math, screenshot classification, persistence.
        .target(
            name: "PeglineCore",
            path: "Sources/PeglineCore"
        ),
        // The app itself: menu bar item, clothesline panel, settings, onboarding.
        .executableTarget(
            name: "Pegline",
            dependencies: ["PeglineCore"],
            path: "Sources/Pegline",
            swiftSettings: [
                .defaultIsolation(MainActor.self)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .testTarget(
            name: "PeglineCoreTests",
            dependencies: ["PeglineCore"],
            path: "Tests/PeglineCoreTests"
        )
    ]
)
