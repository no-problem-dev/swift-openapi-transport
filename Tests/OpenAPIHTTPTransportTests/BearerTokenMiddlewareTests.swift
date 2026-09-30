import Foundation
import HTTPTypes
@_spi(Generated) import OpenAPIRuntime
import OpenAPIHTTPTransport
import Testing

@Suite("BearerTokenMiddleware")
struct BearerTokenMiddlewareTests {
    private let baseURL = URL(string: "https://api.example.com/v1")!

    /// Runs one request through the middleware and a transport over the given mock, the way a
    /// generated client chains them.
    private func send(
        _ middleware: BearerTokenMiddleware,
        over mock: Mock,
        method: HTTPTypes.HTTPRequest.Method = .get,
        body: HTTPBody? = nil
    ) async throws -> HTTPTypes.HTTPResponse {
        let transport = HTTPTransportClientTransport(mock)
        let request = HTTPTypes.HTTPRequest(method: method, scheme: nil, authority: nil, path: "/me")
        let (response, _) = try await middleware.intercept(request, body: body, baseURL: baseURL, operationID: "getMe") {
            try await transport.send($0, body: $1, baseURL: $2, operationID: "getMe")
        }
        return response
    }

    /// A token closure answering `cached` normally and `renewed` when forced, recording each call.
    private func tokens(_ log: TokenLog, cached: String = "old", renewed: String = "new") -> BearerTokenMiddleware {
        BearerTokenMiddleware { forceRefresh in
            await log.record(forceRefresh)
            return forceRefresh ? renewed : cached
        }
    }

    @Test("The token goes out as a bearer credential, asked for without forcing a refresh")
    func attachesToken() async throws {
        let log = TokenLog()
        let mock = server(accepting: "old")
        let response = try await send(tokens(log), over: mock)

        #expect(response.status == .ok)
        #expect(mock.sent.map { $0.header("Authorization") } == ["Bearer old"])
        #expect(await log.calls == [false])
    }

    @Test("A 401 forces a refresh and the request is sent once more with the new token")
    func refreshesOnce() async throws {
        let log = TokenLog()
        let mock = server(accepting: "new")
        let response = try await send(tokens(log), over: mock)

        #expect(response.status == .ok)
        #expect(mock.sent.map { $0.header("Authorization") } == ["Bearer old", "Bearer new"])
        #expect(await log.calls == [false, true])
    }

    @Test("A second 401 is returned as it is, after exactly two attempts")
    func secondUnauthorizedIsFinal() async throws {
        let log = TokenLog()
        let mock = server(accepting: "never")
        let response = try await send(tokens(log), over: mock)

        #expect(response.status == .unauthorized)
        #expect(mock.sent.count == 2)
        #expect(await log.calls == [false, true])
    }

    @Test("When even a forced refresh returns the rejected token, the request is not resent")
    func sameTokenIsNotResent() async throws {
        let log = TokenLog()
        let mock = server(accepting: "never")
        let response = try await send(tokens(log, cached: "old", renewed: "old"), over: mock)

        #expect(response.status == .unauthorized)
        #expect(mock.sent.count == 1)
        #expect(await log.calls == [false, true])
    }

    @Test("Statuses other than 401 are returned without a refresh", arguments: [200, 403, 404, 500])
    func otherStatuses(status: Int) async throws {
        let log = TokenLog()
        let mock = Mock([answer(status)])
        let response = try await send(tokens(log), over: mock)

        #expect(response.status.code == status)
        #expect(mock.sent.count == 1)
        #expect(await log.calls == [false])
    }

    @Test("A body that can be read again is resent with the same bytes")
    func rereadableBodyIsResent() async throws {
        let log = TokenLog()
        let mock = server(accepting: "new")
        let body = HTTPBody(#"{"title":"Kyoto"}"#)
        #expect(body.iterationBehavior == .multiple)
        let response = try await send(tokens(log), over: mock, method: .post, body: body)

        #expect(response.status == .ok)
        #expect(mock.sent.count == 2)
        #expect(mock.sent.allSatisfy { $0.body == Data(#"{"title":"Kyoto"}"#.utf8) })
    }

    @Test("A body readable only once is not resent: the 401 comes back and no refresh is asked for")
    func singleUseBodyIsNotResent() async throws {
        let log = TokenLog()
        let mock = server(accepting: "new")
        let (stream, continuation) = AsyncStream<HTTPBody.ByteChunk>.makeStream()
        continuation.yield(ArraySlice("chunk".utf8))
        continuation.finish()
        let body = HTTPBody(stream, length: .unknown)
        #expect(body.iterationBehavior == .single)

        let response = try await send(tokens(log), over: mock, method: .post, body: body)
        #expect(response.status == .unauthorized)
        #expect(mock.sent.count == 1)
        #expect(mock.sent.first?.body == Data("chunk".utf8))
        #expect(await log.calls == [false])
    }

    @Test("A failure to get the first token is thrown and nothing is sent")
    func firstTokenFails() async throws {
        let mock = Mock()
        let middleware = BearerTokenMiddleware { _ in throw TokenUnavailable() }
        await #expect(throws: TokenUnavailable()) { _ = try await send(middleware, over: mock) }
        #expect(mock.sent.isEmpty)
    }

    @Test("A failure to refresh after a 401 is thrown in place of a second attempt")
    func refreshFails() async throws {
        let mock = server(accepting: "new")
        let middleware = BearerTokenMiddleware { forceRefresh in
            if forceRefresh { throw TokenUnavailable() }
            return "old"
        }
        await #expect(throws: TokenUnavailable()) { _ = try await send(middleware, over: mock) }
        #expect(mock.sent.count == 1)
    }

    @Test("After a refresh fails, the next 401 tries the refresh again")
    func failedRefreshIsNotRemembered() async throws {
        let log = TokenLog()
        let attempts = CallLog()
        let middleware = BearerTokenMiddleware { forceRefresh in
            await log.record(forceRefresh)
            guard forceRefresh else { return "old" }
            attempts.append("refresh")
            if attempts.values.count == 1 { throw TokenUnavailable() }
            return "new"
        }
        let mock = server(accepting: "new")
        await #expect(throws: TokenUnavailable()) { _ = try await send(middleware, over: mock) }
        let response = try await send(middleware, over: mock)

        #expect(response.status == .ok)
        #expect(await log.refreshes == 2)
    }

    @Test("Requests rejected together with the same token share one refresh")
    func concurrentRefreshesCoalesce() async throws {
        let log = TokenLog()
        let middleware = BearerTokenMiddleware { forceRefresh in
            await log.record(forceRefresh)
            guard forceRefresh else { return "old" }
            try await Task.sleep(for: .milliseconds(50))
            return "new"
        }
        let mock = server(accepting: "new")
        let statuses = try await withThrowingTaskGroup(of: HTTPResponse.Status.self) { group in
            for _ in 0..<8 { group.addTask { try await send(middleware, over: mock).status } }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(statuses == Array(repeating: .ok, count: 8))
        #expect(await log.refreshes == 1)
        #expect(mock.sent.filter { $0.header("Authorization") == "Bearer new" }.count == 8)
    }

    @Test("A 401 for the refreshed token starts a new refresh")
    func refreshedTokenCanBeRefreshedAgain() async throws {
        let issued = CallLog()
        let middleware = BearerTokenMiddleware { forceRefresh in
            if forceRefresh { issued.append("t\(issued.values.count + 2)") }
            return issued.values.last ?? "t1"
        }
        let first = try await send(middleware, over: server(accepting: "t2"))
        let second = try await send(middleware, over: server(accepting: "t3"))

        #expect(first.status == .ok)
        #expect(second.status == .ok)
        #expect(issued.values == ["t2", "t3"])
    }

    @Test("Under a generated client, a token failure surfaces as the underlying error of ClientError")
    func underGeneratedClient() async throws {
        let mock = server(accepting: "new")
        let log = TokenLog()
        let client = UniversalClient(
            serverURL: baseURL,
            transport: HTTPTransportClientTransport(mock),
            middlewares: [tokens(log)]
        )
        let status = try await client.send(
            input: (),
            forOperation: "getMe",
            serializer: { _ in (HTTPTypes.HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/me"), nil) },
            deserializer: { response, _ in response.status.code }
        )
        #expect(status == 200)
        #expect(mock.sent.map(\.url.absoluteString) == ["https://api.example.com/v1/me", "https://api.example.com/v1/me"])

        let failing = UniversalClient(
            serverURL: baseURL,
            transport: HTTPTransportClientTransport(mock),
            middlewares: [BearerTokenMiddleware { _ in throw TokenUnavailable() }]
        )
        do {
            _ = try await failing.send(
                input: (),
                forOperation: "getMe",
                serializer: { _ in (HTTPTypes.HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/me"), nil) },
                deserializer: { response, _ in response.status.code }
            )
            Issue.record("Expected a ClientError")
        } catch let error as ClientError {
            #expect(error.underlyingError as? TokenUnavailable == TokenUnavailable())
        }
    }
}
