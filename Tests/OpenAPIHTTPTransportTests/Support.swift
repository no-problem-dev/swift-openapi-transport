import Foundation
import HTTPTransport

// swift-http-transport's `HTTPRequest` and `HTTPResponse` share their names with swift-http-types,
// so this is the only test file that imports swift-http-transport. The others see its values only
// through the helpers below.

typealias Mock = MockTransport

/// A scripted answer for `MockTransport`.
func answer(_ status: Int, headers: [(String, String)] = [], body: String = "") -> MockTransport.Outcome {
    .response(HTTPResponse(status: status, headers: HTTPHeaders(headers), body: Data(body.utf8)))
}

/// A mock that answers 200 to `Authorization: Bearer <accepted>` and 401 to anything else.
func server(accepting accepted: String) -> MockTransport {
    MockTransport { request in
        let ok = request.headers["Authorization"] == "Bearer \(accepted)"
        return HTTPResponse(status: ok ? 200 : 401, headers: [:], body: Data((ok ? "ok" : "unauthorized").utf8))
    }
}

/// `RetryingTransport` over a mock, retrying 503 up to three attempts without sleeping.
func retrying(_ mock: MockTransport) -> any HTTPTransport {
    RetryingTransport(base: mock, policy: ExponentialBackoff(maxAttempts: 3), sleep: { _ in })
}

/// An error a transport throws.
func failing(_ error: any Error) -> MockTransport {
    MockTransport([.failure(error)])
}

/// What one request looked like when it reached the mock.
struct Sent {
    var method: String
    var url: URL
    var headers: [(name: String, value: String)]
    var body: Data?
    var isIdempotent: Bool

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

extension MockTransport {
    var sent: [Sent] {
        recordedRequests.map {
            Sent(method: $0.method, url: $0.url, headers: $0.headers.pairs, body: $0.body, isIdempotent: $0.isIdempotent)
        }
    }
}

/// Records how the token closure was called.
actor TokenLog {
    private(set) var calls: [Bool] = []
    func record(_ forceRefresh: Bool) { calls.append(forceRefresh) }
    var refreshes: Int { calls.filter { $0 }.count }
}

struct TokenUnavailable: Error, Equatable {}
