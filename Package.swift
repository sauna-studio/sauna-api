// swift-tools-version: 6.4
import PackageDescription

// Compiler policy follows the pinned blindlog-api reference; apply to our code,
// not third-party targets. Keep explicit public/package imports at API boundaries.
let apiSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .defaultIsolation(nil),
    .strictMemorySafety(),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "SaunaAPI",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "SaunaAPIContract", targets: ["SaunaAPIContract"]),
        .executable(name: "SaunaAPI", targets: ["SaunaAPI"]),
        .executable(name: "SaunaDBCheck", targets: ["SaunaDBCheck"]),
        .library(name: "SaunaAPIDatabase", targets: ["SaunaAPIDatabase"]),
        .library(name: "SaunaAPIIdentity", targets: ["SaunaAPIIdentity"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.3"),
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.14.3"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", exact: "1.13.3"),
        .package(url: "https://github.com/hummingbird-project/hummingbird", exact: "2.28.1"),
        .package(url: "https://github.com/hummingbird-project/swift-openapi-hummingbird", exact: "2.1.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", exact: "1.33.2"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.16.2"),
    ],
    targets: [
        .target(name: "SaunaAPIIdentity", swiftSettings: apiSwiftSettings),
        .target(name: "SaunaAPIDatabase", dependencies: [.product(name: "Crypto", package: "swift-crypto"), "SaunaAPIIdentity", .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log")], swiftSettings: apiSwiftSettings),
        .executableTarget(name: "SaunaDBCheck", dependencies: ["SaunaAPIDatabase"], swiftSettings: apiSwiftSettings),
        .testTarget(name: "SaunaAPIDatabaseTests", dependencies: ["SaunaAPIDatabase", "SaunaAPIIdentity", .product(name: "Logging", package: "swift-log"), .product(name: "PostgresNIO", package: "postgres-nio")]),
        .target(
            name: "SaunaAPIContract",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")
            ],
            swiftSettings: apiSwiftSettings,
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
            ]
        ),
        .testTarget(name: "SaunaAPIContractTests", dependencies: ["SaunaAPIContract"]),
        .target(
            name: "SaunaAPIServer",
            dependencies: [
                "SaunaAPIContract",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "OpenAPIHummingbird", package: "swift-openapi-hummingbird"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            swiftSettings: apiSwiftSettings
        ),
        .executableTarget(
            name: "SaunaAPI",
            dependencies: ["SaunaAPIServer", .product(name: "Hummingbird", package: "hummingbird")],
            swiftSettings: apiSwiftSettings
        ),
        .testTarget(
            name: "SaunaAPIServerTests",
            dependencies: [
                "SaunaAPIContract", "SaunaAPIServer", "SaunaAPI",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
