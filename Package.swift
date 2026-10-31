// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SaunaAPI",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "SaunaAPIContract", targets: ["SaunaAPIContract"]),
        .executable(name: "SaunaAPI", targets: ["SaunaAPI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.14.3"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", exact: "1.13.3"),
        .package(url: "https://github.com/hummingbird-project/hummingbird", exact: "2.28.1"),
        .package(url: "https://github.com/hummingbird-project/swift-openapi-hummingbird", exact: "2.1.0"),
    ],
    targets: [
        .target(
            name: "SaunaAPIContract",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")
            ],
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
            ]
        ),
        .executableTarget(
            name: "SaunaAPI",
            dependencies: ["SaunaAPIServer", .product(name: "Hummingbird", package: "hummingbird")]
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
