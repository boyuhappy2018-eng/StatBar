// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StatBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "StatBar", targets: ["StatBar"]),
        .executable(name: "StatBarSMCHelper", targets: ["StatBarSMCHelper"])
    ],
    targets: [
        .target(
            name: "CHIDBridge",
            linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("IOKit")]
        ),
        .target(
            name: "SMCCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "StatBar",
            dependencies: ["SMCCore", "CHIDBridge"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Charts"),
                .linkedFramework("IOKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("EventKit"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "StatBarSMCHelper",
            dependencies: ["SMCCore"],
            linkerSettings: [.linkedFramework("IOKit")]
        )
    ],
    swiftLanguageModes: [.v5]
)
