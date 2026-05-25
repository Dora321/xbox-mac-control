// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "XboxMacControl",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "xbox-scroll", targets: ["XboxScroll"])
    ],
    targets: [
        .executableTarget(
            name: "XboxScroll",
            path: "Sources/XboxScroll"
        )
    ]
)
