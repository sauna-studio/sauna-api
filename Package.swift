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
        .package(url: "https://github.com/brokenhandsio/swift-cbor.git", exact: "0.2.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
        .package(url: "https://github.com/apple/swift-http-types", exact: "1.8.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", exact: "2.13.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.0.0"),
        .package(url: "https://github.com/zunda-pixel/swift-currency.git", from: "0.0.1"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-auth.git", from: "2.0.0"),
        .package(url: "https://github.com/vapor/postgres-kit.git", from: "2.0.0"),
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.4.0"),
        .package(url: "https://github.com/zunda-pixel/cloudflare-swift.git", from: "0.8.2"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-postgres.git", from: "1.0.0"),
        .package(url: "https://github.com/valkey-io/valkey-swift.git", from: "1.3.0"),
        .package(url: "https://github.com/swift-otel/swift-otel.git", from: "1.0.0"),
        // Based on upstream PR #128, with only reviewed compatibility fixes.
        .package(url: "https://github.com/zunda-pixel/swift-webauthn.git", revision: "0d1a4e6408f0a611a98b408ab6a465e40303ac7c"),
        .package(url: "https://github.com/zunda-pixel/UUIDV7.git", branch: "replace-to-swift-testing"),
        .package(url: "https://github.com/zunda-pixel/swift-postgresql.git", branch: "fix-postgresql-closure-lifetime", traits: ["PostgresNIO"]),
        .package(url: "https://github.com/swift-compositions/swift-sql.git", branch: "main"),
        .package(url: "https://github.com/swift-iso/swift-iso-9075.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.3"),
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.14.3"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", exact: "1.13.3"),
        .package(url: "https://github.com/hummingbird-project/hummingbird", exact: "2.28.1"),
        .package(url: "https://github.com/hummingbird-project/swift-openapi-hummingbird", exact: "2.1.0"),
        .package(url: "https://github.com/sauna-studio/postgres-nio.git", revision: "5722f49dad5eb951522afafa57320ad3f9ea69d2"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.16.2"),
    ],
    targets: [
        .target(name: "SaunaAPIIdentity", dependencies: [.product(name: "NIOCore", package: "swift-nio"), .product(name: "ISO 9075 Foundation", package: "swift-iso-9075"), .product(name: "PostgreSQL", package: "swift-postgresql"), .product(name: "SQL", package: "swift-sql"), .product(name: "SQL Macros", package: "swift-sql"), .product(name: "SQL Foundation Integration", package: "swift-sql"), .product(name: "WebAuthn", package: "swift-webauthn"), .product(name: "CBOR", package: "swift-cbor"), .product(name: "Crypto", package: "swift-crypto"), .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log")], swiftSettings: apiSwiftSettings),
        .testTarget(name: "SaunaAPIIdentityTests", dependencies: ["SaunaAPIDatabase", "SaunaAPIIdentity", .product(name: "WebAuthn", package: "swift-webauthn"), .product(name: "CBOR", package: "swift-cbor"), .product(name: "Crypto", package: "swift-crypto"), .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log")]),
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
                "SaunaAPIContract", "SaunaAPIIdentity",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "OpenAPIHummingbird", package: "swift-openapi-hummingbird"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            swiftSettings: apiSwiftSettings
        ),
        .executableTarget(
            name: "SaunaAPI",
            dependencies: ["SaunaAPIServer", "SaunaAPIDatabase", "SaunaAPIIdentity", .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"), .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Hummingbird", package: "hummingbird")],
            swiftSettings: apiSwiftSettings
        ),
        .testTarget(
            name: "SaunaAPIServerTests",
            dependencies: [
                "SaunaAPIContract", "SaunaAPIServer", "SaunaAPI", "SaunaAPIDatabase", "SaunaAPIIdentity",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
