// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SaunaAPI",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "SaunaAPIContract", targets: ["SaunaAPIContract"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.14.3"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", exact: "1.13.3"),
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
    ]
)
