# OpenAPIHTTPTransport

English | [日本語](./README.ja.md)

Run a client made by [swift-openapi-generator](https://github.com/apple/swift-openapi-generator) on [swift-http-transport](https://github.com/no-problem-dev/swift-http-transport), with a bearer token that is renewed once when the server answers 401.

![Swift 6.2+](https://img.shields.io/badge/Swift-6.2+-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2017%20%7C%20macOS%2014%20%7C%20tvOS%2017%20%7C%20watchOS%2010%20%7C%20visionOS%201-blue.svg)
![License](https://img.shields.io/badge/License-MIT-green.svg)

## Features

- **A `ClientTransport` over swift-http-transport**: `HTTPTransportClientTransport` sends through any `HTTPTransport`. Wrap it in `RetryingTransport` for backoff and `Retry-After`, or pass `MockTransport` in tests
- **Retry decided per operation**: `isIdempotent` receives the `operationId` and the method, and its answer is what `RetryingTransport` checks before replaying. The default follows RFC 9110, so a POST is never replayed unless you say it may be
- **A 401 is answered with a forced refresh, once**: `BearerTokenMiddleware` asks for a token with `forceRefresh: false`, and after a 401 asks again with `forceRefresh: true` and resends. A second 401 is returned as is. If the refreshed token equals the rejected one, nothing is resent
- **One refresh for requests that fail together**: requests rejected with the same token wait for a single refresh, and a request that learns of its 401 afterwards reuses the result
- **Bodies that cannot be read twice are not resent**: when the request body is `.single`, the 401 is returned instead of a second attempt with an empty body
- **The token is a closure**: `@Sendable (_ forceRefresh: Bool) async throws -> String`. No protocol to conform to, so any authentication library fits in one line
- **Low version floors**: swift-openapi-runtime from 1.0.0, swift-http-types from 1.0.0 and swift-http-transport from 2.0.0. It does not depend on the generator or on swift-openapi-urlsession

## Usage

```swift
import HTTPTransport          // only in the file that builds the client
import OpenAPIHTTPTransport

let client = Client(
    serverURL: try Servers.Server1.url(),
    transport: HTTPTransportClientTransport(
        RetryingTransport(base: URLSessionTransport(), policy: ExponentialBackoff()),
        isIdempotent: { operationID, method in
            // The server deduplicates row pushes by their stamp, so replaying one is safe.
            operationID == "pushRows" || HTTPTransportClientTransport.defaultIdempotency(operationID, method)
        }
    ),
    middlewares: [
        LoggingMiddleware(),
        // Last, so the middlewares above see only the final response.
        BearerTokenMiddleware { forceRefresh in
            guard let token = try await auth.token(forceRefresh: forceRefresh) else {
                throw NotSignedIn()   // fail before sending rather than send without credentials
            }
            return token
        },
    ]
)
```

swift-http-types (used by generated code) and swift-http-transport both declare `HTTPRequest` and `HTTPResponse`. This package does not re-export swift-http-transport, so import `HTTPTransport` only in the file that builds the client. Everywhere else, `HTTPRequest` keeps meaning the swift-http-types one.

Server-sent events and other long-lived bodies do not go through the generated client: bodies here are buffered. Read streams with `HTTPStreamingTransport` directly.

## Documentation

The API reference lives in the DocC catalog [`Sources/OpenAPIHTTPTransport/Documentation.docc`](Sources/OpenAPIHTTPTransport/Documentation.docc).

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/no-problem-dev/swift-openapi-transport.git", .upToNextMinor(from: "0.1.0"))
]
```

Then add the product to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "OpenAPIHTTPTransport", package: "swift-openapi-transport")
    ]
)
```

## License

MIT License - See [LICENSE](LICENSE) for details.
