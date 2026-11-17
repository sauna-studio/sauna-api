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
    .package(url: "https://github.com/apple/swift-openapi-generator.git", from: "1.14.3"),
    .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.13.3"),
    .package(url: "https://github.com/swift-compositions/swift-sql.git", branch: "main"),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.28.1"),
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
    .package(
      url: "https://github.com/sauna-studio/postgres-nio.git",
      revision: "1b9c2a873ee6c5dfa33bdb0370f3537c361e801f"
    ),
  ],
  targets: [
    .target(
      name: "SaunaAPIIdentity",
      dependencies: [
        .product(name: "PostgreSQL", package: "swift-postgresql"),
        .product(name: "SQL Macros", package: "swift-sql"),
        .product(name: "SQL Foundation Integration", package: "swift-sql"),
        .product(name: "WebAuthn", package: "swift-webauthn"),
      ],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "SaunaAPIIdentityTests",
      dependencies: [.target(name: "SaunaAPIDatabase")]
    ),
    .target(
      name: "SaunaAPIDatabase",
      dependencies: [.target(name: "SaunaAPIIdentity")],
      swiftSettings: swiftSettings
    ),
    .executableTarget(
      name: "SaunaDBCheck",
      dependencies: [.target(name: "SaunaAPIDatabase")],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "SaunaAPIDatabaseTests",
      dependencies: [.target(name: "SaunaAPIDatabase")]
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
    .testTarget(name: "SaunaAPIContractTests", dependencies: [.target(name: "SaunaAPIContract")]),
    .target(
      name: "SaunaAPIServer",
      dependencies: [
        .target(name: "SaunaAPIContract"), .target(name: "SaunaAPIDatabase"),
        .product(name: "OpenAPIHummingbird", package: "swift-openapi-hummingbird"),
        .product(name: "OTel", package: "swift-otel"),
      ],
      swiftSettings: swiftSettings
    ),
    .executableTarget(
      name: "SaunaAPI",
      dependencies: [.target(name: "SaunaAPIServer")],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "SaunaAPIServerTests",
      dependencies: [
        .target(name: "SaunaAPI"), .product(name: "HummingbirdTesting", package: "hummingbird"),
      ],
      resources: [.copy("Fixtures")]
    ),
  ]
)
