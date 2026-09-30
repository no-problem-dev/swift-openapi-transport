import Foundation
import HTTPTransport

// swift-http-types and swift-http-transport both declare `HTTPRequest` and `HTTPResponse`, and a
// module-qualified name does not help because `HTTPTransport` is also the name of a protocol inside
// the `HTTPTransport` module. This file therefore imports only swift-http-transport, and everything
// that touches its message types lives here, described in plain values the other files can use.

/// What went out on the wire, in the shape swift-http-transport describes it.
struct WireRequest: Sendable {
    var method: String
    var url: URL
    var headers: [(name: String, value: String)]
    var body: Data?
    var isIdempotent: Bool
}

/// What came back, fully buffered, before it is turned into swift-http-types values.
struct WireResponse: Sendable {
    var status: Int
    var headers: [(name: String, value: String)]
    var body: Data
}

extension WireRequest {
    /// Sends through the given transport and waits for the whole response.
    ///
    /// A non-2xx status comes back as a response, never as an error, which is what the generated
    /// client expects: it maps every status to a case of the operation's output.
    func send(through transport: any HTTPTransport) async throws -> WireResponse {
        let request = HTTPRequest(
            method: method,
            url: url,
            headers: HTTPHeaders(headers.map { ($0.name, $0.value) }),
            body: body,
            isIdempotent: isIdempotent
        )
        let response = try await transport.send(request)
        return WireResponse(status: response.status, headers: response.headers.pairs, body: response.body)
    }
}
