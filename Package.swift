// swift-tools-version: 6.4
import PackageDescription

// Compiler policy follows the pinned blindlog-api reference; apply to our code,
// not third-party targets. Keep explicit public/package imports at API boundaries.
let swiftSettings: [SwiftSetting] = [
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
    .package(url: "https://github.com/brokenhandsio/swift-cbor.git", from: "0.3.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
    .package(url: "https://github.com/apple/swift-http-types", from: "1.8.0"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.13.0"),
    .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.7.3"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.3"),
    .package(url: "https://github.com/apple/swift-openapi-generator.git", from: "1.14.3"),
    .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.13.3"),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.28.1"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.16.2"),
    .package(
      url: "https://github.com/hummingbird-project/swift-openapi-hummingbird",
      from: "2.1.0"
    ),
    .package(
      url: "https://github.com/swift-otel/swift-otel.git",
      from: "1.0.0",
      traits: ["OTLPHTTP"]
    ),
	.package(url: "https://github.com/brokenhandsio/swift-webauthn.git", from: "1.0.0-beta.3"),
    .package(
      url: "https://github.com/zunda-pixel/swift-postgresql.git",
      branch: "fix-postgresql-closure-lifetime", traits: ["PostgresNIO"]
    ),
    // Keep compatible SQL/ISO9075 revisions in Package.resolved until the PostgreSQL
    // adapter supports the new protocol; revision overrides conflict with main (#86).
    .package(url: "https://github.com/swift-compositions/swift-sql.git", branch: "main"),
    .package(
      url: "https://github.com/swift-iso/swift-iso-9075.git",
      branch: "main"
    ),
    .package(
      url: "https://github.com/sauna-studio/postgres-nio.git",
      revision: "1b9c2a873ee6c5dfa33bdb0370f3537c361e801f"
    ),
  ],
  targets: [
    .target(
      name: "SaunaAPIIdentity",
      dependencies: [
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "ISO 9075 Foundation", package: "swift-iso-9075"),
        .product(name: "PostgreSQL", package: "swift-postgresql"),
        .product(name: "SQL", package: "swift-sql"),
        .product(name: "SQL Macros", package: "swift-sql"),
        .product(name: "SQL Foundation Integration", package: "swift-sql"),
        .product(name: "WebAuthn", package: "swift-webauthn"),
        .product(name: "CBOR", package: "swift-cbor"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "PostgresNIO", package: "postgres-nio"),
        .product(name: "Logging", package: "swift-log"),
      ],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "SaunaAPIIdentityTests",
      dependencies: [
        .target(name: "SaunaAPIDatabase"),
        .target(name: "SaunaAPIIdentity"),
        .product(name: "WebAuthn", package: "swift-webauthn"),
        .product(name: "CBOR", package: "swift-cbor"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "PostgresNIO", package: "postgres-nio"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .target(
      name: "SaunaAPIDatabase",
      dependencies: [
        .target(name: "SaunaAPIIdentity"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "PostgresNIO", package: "postgres-nio"),
        .product(name: "Logging", package: "swift-log"),
      ],
      swiftSettings: swiftSettings
    ),
    .executableTarget(
      name: "SaunaDBCheck",
      dependencies: [
        .target(name: "SaunaAPIDatabase")
      ],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "SaunaAPIDatabaseTests",
      dependencies: [
        .target(name: "SaunaAPIDatabase"),
        .target(name: "SaunaAPIIdentity"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "PostgresNIO", package: "postgres-nio"),
      ]
    ),
    .target(
      name: "SaunaAPIContract",
      dependencies: [
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")
      ],
      swiftSettings: swiftSettings,
      plugins: [
        .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
      ]
    ),
    .testTarget(name: "SaunaAPIContractTests", dependencies: ["SaunaAPIContract"]),
    .target(
      name: "SaunaAPIServer",
      dependencies: [
        .target(name: "SaunaAPIContract"),
        .target(name: "SaunaAPIIdentity"),
        .target(name: "SaunaAPIDatabase"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        .product(name: "PostgresNIO", package: "postgres-nio"),
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "OpenAPIHummingbird", package: "swift-openapi-hummingbird"),
        .product(name: "OTel", package: "swift-otel"),
        .product(name: "Tracing", package: "swift-distributed-tracing"),
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
      ],
      swiftSettings: swiftSettings
    ),
    .executableTarget(
      name: "SaunaAPI",
      dependencies: [
        .target(name: "SaunaAPIServer"),
        .target(name: "SaunaAPIDatabase"),
        .target(name: "SaunaAPIIdentity"),
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        .product(name: "PostgresNIO", package: "postgres-nio"),
        .product(name: "Hummingbird", package: "hummingbird"),
      ],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "SaunaAPIServerTests",
      dependencies: [
        .target(name: "SaunaAPIContract"),
        .target(name: "SaunaAPIServer"),
        .target(name: "SaunaAPI"),
        .target(name: "SaunaAPIDatabase"),
        .target(name: "SaunaAPIIdentity"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "CBOR", package: "swift-cbor"),
        .product(name: "PostgresNIO", package: "postgres-nio"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
        .product(name: "HummingbirdTesting", package: "hummingbird"),
      ],
      resources: [.copy("Fixtures")]
    ),
  ]
)
