// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "termu",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "termu", targets: ["Termu"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0")
    ],
    targets: [
        .executableTarget(
            name: "Termu",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/Termu"
        ),
        .testTarget(
            name: "TermuTests",
            dependencies: ["Termu"],
            path: "Tests/TermuTests"
        )
    ]
)
