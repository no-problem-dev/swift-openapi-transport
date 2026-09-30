import Foundation
import HTTPTransport
import HTTPTypes
import OpenAPIRuntime

/// A `ClientTransport` for generated OpenAPI clients that sends through swift-http-transport.
///
/// Put this under a generated `Client` and everything swift-http-transport offers applies to the
/// generated operations: wrap the transport in `RetryingTransport` for backoff and `Retry-After`,
/// or pass a `MockTransport` in tests. Retrying is not done here; this type only decides, per
/// operation, whether a request may be delivered twice.
///
/// ```swift
/// import HTTPTransport          // only in the file that builds the client
/// import OpenAPIHTTPTransport
///
/// let client = Client(
///     serverURL: serverURL,
///     transport: HTTPTransportClientTransport(
///         RetryingTransport(base: URLSessionTransport(), policy: ExponentialBackoff()),
///         isIdempotent: { operationID, method in
///             operationID == "pushRows" || HTTPTransportClientTransport.defaultIdempotency(operationID, method)
///         }
///     ),
///     middlewares: [BearerTokenMiddleware(token: { try await auth.token(forceRefresh: $0) })]
/// )
/// ```
///
/// Bodies are buffered. The request body is collected into memory before it is sent, up to
/// ``maxRequestBodyBytes``, and the response body is fully in memory by the time the generated
/// client sees it, because `HTTPTransport.send(_:)` returns only once the whole response has
/// arrived. Server-sent events and other long-lived streams do not belong on this path; read them
/// with `HTTPStreamingTransport` directly.
public struct HTTPTransportClientTransport: ClientTransport {
    /// Whether an operation may be delivered twice, given its `operationId` and HTTP method.
    ///
    /// The answer becomes the request's `isIdempotent`, which is what `RetryingTransport` checks
    /// before replaying anything.
    public typealias Idempotency = @Sendable (_ operationID: String, _ method: String) -> Bool

    /// The methods RFC 9110 §9.2.2 defines as idempotent: GET, HEAD, PUT, DELETE, OPTIONS and TRACE.
    ///
    /// POST and PATCH are not, and neither is any extension method. The operation ID is ignored.
    /// Build on this when only a few operations need a different answer, such as a POST the server
    /// deduplicates by a key in its body.
    public static let defaultIdempotency: Idempotency = { _, method in
        ["GET", "HEAD", "PUT", "DELETE", "OPTIONS", "TRACE"].contains(method.uppercased())
    }

    /// The largest request body collected before sending, in bytes.
    ///
    /// A larger body fails the call before anything is sent.
    public let maxRequestBodyBytes: Int

    private let transport: any HTTPTransport
    private let isIdempotent: Idempotency

    /// Creates a transport for a generated client.
    ///
    /// - Parameters:
    ///   - transport: What actually sends the request. Wrap it in `RetryingTransport` to retry.
    ///   - maxRequestBodyBytes: The largest request body collected before sending. Defaults to
    ///     16 MiB.
    ///   - isIdempotent: Decides from the operation ID and the method whether a request may be
    ///     delivered twice. Defaults to ``defaultIdempotency``.
    public init(
        _ transport: any HTTPTransport,
        maxRequestBodyBytes: Int = 16 << 20,
        isIdempotent: @escaping Idempotency = defaultIdempotency
    ) {
        self.transport = transport
        self.maxRequestBodyBytes = maxRequestBodyBytes
        self.isIdempotent = isIdempotent
    }

    public func send(
        _ request: HTTPTypes.HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPTypes.HTTPResponse, HTTPBody?) {
        let method = request.method.rawValue
        let url = try Self.url(baseURL: baseURL, path: request.path)
        var bytes: Data?
        if let body { bytes = try await Data(collecting: body, upTo: maxRequestBodyBytes) }
        let wire = WireRequest(
            method: method,
            url: url,
            headers: Self.pairs(from: request.headerFields),
            body: bytes,
            isIdempotent: isIdempotent(operationID, method)
        )
        let response = try await wire.send(through: transport)
        return (
            HTTPTypes.HTTPResponse(
                status: .init(code: response.status),
                headerFields: Self.fields(from: response.headers)
            ),
            HTTPBody(response.body)
        )
    }

    /// Appends the request's path and query to the server URL, keeping any path the server URL has.
    ///
    /// The server URL of a generated client often carries a prefix such as `/v1`, and the request
    /// path is relative to it, so the two are concatenated rather than resolved.
    static func url(baseURL: URL, path: String?) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let requested = URLComponents(string: path ?? "")
        else { throw RequestURLError(baseURL: baseURL, path: path) }
        components.percentEncodedPath += requested.percentEncodedPath
        components.percentEncodedQuery = requested.percentEncodedQuery
        guard let url = components.url else { throw RequestURLError(baseURL: baseURL, path: path) }
        return url
    }

    /// One pair per field name, in first-seen order.
    ///
    /// `HTTPHeaders` holds each name once, so a name that appears more than once is sent as the
    /// single value `HTTPFields` joins it into: comma-separated, or semicolon-separated for `Cookie`.
    static func pairs(from fields: HTTPFields) -> [(name: String, value: String)] {
        var seen: Set<HTTPField.Name> = []
        var pairs: [(name: String, value: String)] = []
        for field in fields where seen.insert(field.name).inserted {
            pairs.append((field.name.rawName, fields[field.name] ?? field.value))
        }
        return pairs
    }

    /// The response's fields as `HTTPFields`.
    ///
    /// A name that is not a valid HTTP token cannot be represented in `HTTPFields` and is left out.
    /// `URLSession` does not produce such names; only a hand-built response could.
    static func fields(from pairs: [(name: String, value: String)]) -> HTTPFields {
        var fields = HTTPFields()
        for pair in pairs {
            guard let name = HTTPField.Name(pair.name) else { continue }
            fields.append(HTTPField(name: name, value: pair.value))
        }
        return fields
    }
}

/// The server URL and the request path could not be combined into a URL.
///
/// Thrown before anything is sent. The generated client reports it as the underlying error of a
/// `ClientError`.
public struct RequestURLError: Error, Sendable, CustomStringConvertible {
    /// The server URL the generated client was created with.
    public let baseURL: URL
    /// The path and query of the operation, as the generated client built it.
    public let path: String?

    public var description: String {
        "Cannot append the request path \(path ?? "nil") to the server URL \(baseURL.absoluteString)"
    }
}
