// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-openapi-transport",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "OpenAPIHTTPTransport",
            targets: ["OpenAPIHTTPTransport"]
        ),
    ],
    dependencies: [
        // The lowest 1.x is enough: ClientTransport, ClientMiddleware and HTTPBody have had
        // their current shape since 1.0.0. A higher floor would lock out apps whose generator
        // pins an older runtime.
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
        // Already in the graph through the runtime; declared because this package's own
        // sources name its types.
        .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0"),
        .package(url: "https://github.com/no-problem-dev/swift-http-transport.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "OpenAPIHTTPTransport",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "HTTPTransport", package: "swift-http-transport"),
            ]
        ),
        .testTarget(
            name: "OpenAPIHTTPTransportTests",
            dependencies: [
                "OpenAPIHTTPTransport",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "HTTPTransport", package: "swift-http-transport"),
            ]
        ),
    ]
)
