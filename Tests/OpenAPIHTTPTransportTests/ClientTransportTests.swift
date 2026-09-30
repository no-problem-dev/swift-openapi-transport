import Foundation
import HTTPTypes
import OpenAPIHTTPTransport
import OpenAPIRuntime
import Testing

@Suite("HTTPTransportClientTransport")
struct ClientTransportTests {
    private let baseURL = URL(string: "https://api.example.com/v1")!

    private func get(_ path: String, fields: HTTPFields = [:]) -> HTTPTypes.HTTPRequest {
        HTTPTypes.HTTPRequest(method: .get, scheme: nil, authority: nil, path: path, headerFields: fields)
    }

    @Test("The request path and query are appended to the server URL, keeping its prefix")
    func url() async throws {
        let mock = Mock()
        let transport = HTTPTransportClientTransport(mock)
        _ = try await transport.send(get("/trips/t%201/rows?since=5&limit=2"), body: nil, baseURL: baseURL, operationID: "pull")
        #expect(mock.sent.first?.url.absoluteString == "https://api.example.com/v1/trips/t%201/rows?since=5&limit=2")
        #expect(mock.sent.first?.method == "GET")
    }

    @Test("A server URL without a path takes the request path as it is")
    func urlWithoutPrefix() async throws {
        let mock = Mock()
        _ = try await HTTPTransportClientTransport(mock)
            .send(get("/health"), body: nil, baseURL: URL(string: "https://api.example.com")!, operationID: "health")
        #expect(mock.sent.first?.url.absoluteString == "https://api.example.com/health")
    }

    @Test("Header fields go out once per name; a repeated name is joined into one value")
    func requestHeaders() async throws {
        let mock = Mock()
        var fields: HTTPFields = [.accept: "application/json", .acceptLanguage: "ja"]
        fields.append(HTTPField(name: .accept, value: "text/plain"))
        fields.append(HTTPField(name: HTTPField.Name("X-Trace")!, value: "abc"))
        _ = try await HTTPTransportClientTransport(mock).send(get("/x", fields: fields), body: nil, baseURL: baseURL, operationID: "x")

        let sent = try #require(mock.sent.first)
        #expect(sent.headers.map(\.name) == ["Accept", "Accept-Language", "X-Trace"])
        #expect(sent.header("accept") == "application/json, text/plain")
        #expect(sent.header("X-Trace") == "abc")
    }

    @Test("The response keeps its status, header fields and body")
    func response() async throws {
        let mock = Mock([answer(422, headers: [("Content-Type", "application/json"), ("Retry-After", "3")], body: #"{"code":"bad"}"#)])
        let (response, body) = try await HTTPTransportClientTransport(mock)
            .send(get("/x"), body: nil, baseURL: baseURL, operationID: "x")

        #expect(response.status.code == 422)
        #expect(response.headerFields[.contentType] == "application/json")
        #expect(response.headerFields[.retryAfter] == "3")
        let bytes = try await Data(collecting: try #require(body), upTo: 1024)
        #expect(String(decoding: bytes, as: UTF8.self) == #"{"code":"bad"}"#)
    }

    @Test("A body built from data is sent as its bytes, and no body is sent as none")
    func requestBody() async throws {
        let mock = Mock()
        let transport = HTTPTransportClientTransport(mock)
        let post = HTTPTypes.HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/notes")
        _ = try await transport.send(post, body: HTTPBody(#"{"a":1}"#), baseURL: baseURL, operationID: "create")
        _ = try await transport.send(get("/notes"), body: nil, baseURL: baseURL, operationID: "list")

        #expect(mock.sent[0].body == Data(#"{"a":1}"#.utf8))
        #expect(mock.sent[1].body == nil)
    }

    @Test("A body that streams in chunks, readable once, is collected and sent whole")
    func streamedBody() async throws {
        let mock = Mock()
        let (stream, continuation) = AsyncStream<HTTPBody.ByteChunk>.makeStream()
        continuation.yield(ArraySlice("first,".utf8))
        continuation.yield(ArraySlice("second".utf8))
        continuation.finish()
        let body = HTTPBody(stream, length: .unknown)
        #expect(body.iterationBehavior == .single)

        let post = HTTPTypes.HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/upload")
        _ = try await HTTPTransportClientTransport(mock).send(post, body: body, baseURL: baseURL, operationID: "upload")
        #expect(mock.sent.first?.body == Data("first,second".utf8))
    }

    @Test("A request body over the limit fails before anything is sent")
    func bodyLimit() async throws {
        let mock = Mock()
        let transport = HTTPTransportClientTransport(mock, maxRequestBodyBytes: 4)
        let post = HTTPTypes.HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/notes")
        await #expect(throws: (any Error).self) {
            _ = try await transport.send(post, body: HTTPBody("12345"), baseURL: baseURL, operationID: "create")
        }
        #expect(mock.sent.isEmpty)
    }

    @Test("By default only the RFC 9110 idempotent methods may be delivered twice", arguments: [
        ("GET", true), ("HEAD", true), ("PUT", true), ("DELETE", true), ("OPTIONS", true), ("TRACE", true),
        ("POST", false), ("PATCH", false), ("QUERY", false), ("get", true),
    ])
    func defaultIdempotency(method: String, expected: Bool) {
        #expect(HTTPTransportClientTransport.defaultIdempotency("anyOperation", method) == expected)
    }

    @Test("The idempotency closure sees the operation ID and method, and its answer reaches the request")
    func customIdempotency() async throws {
        let mock = Mock()
        let seen = CallLog()
        let transport = HTTPTransportClientTransport(mock, isIdempotent: { operationID, method in
            seen.append("\(operationID) \(method)")
            return operationID == "pushRows"
        })
        let post = HTTPTypes.HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/rows")
        _ = try await transport.send(post, body: nil, baseURL: baseURL, operationID: "pushRows")
        _ = try await transport.send(post, body: nil, baseURL: baseURL, operationID: "createTrip")

        #expect(seen.values == ["pushRows POST", "createTrip POST"])
        #expect(mock.sent.map(\.isIdempotent) == [true, false])
    }

    @Test("Under RetryingTransport, a POST marked idempotent is retried and an unmarked one is not")
    func retryFollowsIdempotency() async throws {
        let post = HTTPTypes.HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/rows")

        let marked = Mock([answer(503), answer(200)])
        let (retried, _) = try await HTTPTransportClientTransport(retrying(marked), isIdempotent: { _, _ in true })
            .send(post, body: HTTPBody("row"), baseURL: baseURL, operationID: "pushRows")
        #expect(retried.status.code == 200)
        #expect(marked.sent.count == 2)
        #expect(marked.sent.allSatisfy { $0.body == Data("row".utf8) })

        let unmarked = Mock([answer(503), answer(200)])
        let (final, _) = try await HTTPTransportClientTransport(retrying(unmarked))
            .send(post, body: HTTPBody("row"), baseURL: baseURL, operationID: "createTrip")
        #expect(final.status.code == 503)
        #expect(unmarked.sent.count == 1)
    }

    @Test("An error from the transport is thrown unchanged")
    func transportError() async throws {
        let transport = HTTPTransportClientTransport(failing(URLError(.notConnectedToInternet)))
        await #expect(throws: URLError.self) {
            _ = try await transport.send(get("/x"), body: nil, baseURL: baseURL, operationID: "x")
        }
    }
}

/// A lock-guarded list, for recording calls from a `@Sendable` closure.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ value: String) { lock.withLock { stored.append(value) } }
    var values: [String] { lock.withLock { stored } }
}
