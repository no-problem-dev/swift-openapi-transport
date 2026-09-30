# ``OpenAPIHTTPTransport``

Run a client made by swift-openapi-generator on swift-http-transport, with a bearer token that is
renewed once when the server answers 401.

@Metadata {
    @PageColor(blue)
}

## Overview

A generated `Client` sends through a `ClientTransport` and passes every request through a list of
`ClientMiddleware`. This package supplies one of each:

- ``HTTPTransportClientTransport`` sends through any `HTTPTransport` from swift-http-transport, so
  retries, `Retry-After` and test doubles come from there. It decides per operation whether a
  request may be delivered twice, which is what `RetryingTransport` checks before replaying.
- ``BearerTokenMiddleware`` sends `Authorization: Bearer <token>`. After a 401 it asks for a new
  token with `forceRefresh: true` and sends the request once more. Requests rejected together share
  one refresh.

The token is a closure, `@Sendable (_ forceRefresh: Bool) async throws -> String`, not a protocol,
so it adapts to any authentication library in one line at the composition root.

```swift
import HTTPTransport          // only in the file that builds the client
import OpenAPIHTTPTransport

let client = Client(
    serverURL: try Servers.Server1.url(),
    transport: HTTPTransportClientTransport(
        RetryingTransport(base: URLSessionTransport(), policy: ExponentialBackoff())
    ),
    middlewares: [
        LoggingMiddleware(),
        BearerTokenMiddleware { forceRefresh in
            try await session.idToken(forceRefresh: forceRefresh)
        },
    ]
)
```

### Keep swift-http-transport in one file

swift-http-types, which generated code uses, and swift-http-transport both declare `HTTPRequest`
and `HTTPResponse`. This package does not re-export swift-http-transport, and no public declaration
here names one of its types except the transport the initializer takes. Import `HTTPTransport` only
in the file that builds the client; everywhere else, `HTTPRequest` then means the swift-http-types
one that middlewares and generated code use.

### Order of middlewares

The first middleware in the list is the outermost. Put ``BearerTokenMiddleware`` last, so that
logging or error-reporting middlewares see one final response instead of the 401 that a refresh
has already answered.

### What stays outside

Server-sent events and other long-lived bodies are not read through a generated client. The
request body is collected into memory before it is sent, and the response body is fully buffered
by `HTTPTransport.send(_:)`. Read streams with `HTTPStreamingTransport` directly.

## Topics

### Sending

- ``HTTPTransportClientTransport``
- ``RequestURLError``

### Authorization

- ``BearerTokenMiddleware``
