// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-cipher",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2)
    ],
    products: [
        .library(
            name: "SwiftCipher",
            targets: ["SwiftCipher"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/skiptools/swift-sqlcipher.git", exact: "1.7.1")
    ],
    targets: [
        .target(
            name: "SwiftCipher",
            dependencies: [
                .product(name: "SQLiteDB", package: "swift-sqlcipher")
            ],
            path: "Sources/SwiftCipher",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "SwiftCipherTests",
            dependencies: [
                "SwiftCipher",
                .product(name: "SQLiteDB", package: "swift-sqlcipher")
            ],
            path: "Tests/SwiftCipherTests"
        )
    ]
)
