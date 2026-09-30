import Foundation
import HTTPTypes
import OpenAPIRuntime

/// A `ClientMiddleware` that sends a bearer token and renews it once when the server answers 401.
///
/// Every request asks for a token with `forceRefresh: false` and carries it as
/// `Authorization: Bearer <token>`. When the answer is `401 Unauthorized`, the middleware asks
/// again with `forceRefresh: true` and sends the request once more with the new token. What the
/// second attempt returns is final: a second 401 comes back to the caller unchanged.
///
/// Asking with `forceRefresh: true` is the point. An ID token provider that answers from its cache
/// hands back the same expired token after a 401, and a client that resends with it only collects a
/// second 401. For the same reason the request is not resent when even a forced refresh returns the
/// token that was just rejected.
///
/// ### When the request is not resent
///
/// - The status is anything other than 401. A 403 means the token was read and refused, which a new
///   token does not change.
/// - The request body can be read only once (`HTTPBody.iterationBehavior == .single`), such as a
///   body built from an `AsyncStream`. The first attempt consumed it, so the 401 is returned as is.
///   A body built from `Data`, a string or an array can be read again and is resent.
/// - The refreshed token equals the one the server rejected.
///
/// ### Requests that fail together share one refresh
///
/// Requests that were sent with the same token and are answered 401 at about the same time wait for
/// one forced refresh instead of starting one each. A request that learns of its 401 after that
/// refresh has finished reuses its result. A 401 for the refreshed token starts a new refresh.
///
/// ### Errors
///
/// An error thrown by the token closure is thrown from the call, before the first attempt or in
/// place of the second. The generated client reports it as the underlying error of a `ClientError`.
///
/// Put this middleware last in the list if other middlewares should see only the final response.
public struct BearerTokenMiddleware: ClientMiddleware {
    private let tokens: TokenSource

    /// Creates the middleware.
    ///
    /// - Parameter token: Returns the token to send. `forceRefresh` is `false` for an ordinary
    ///   request and `true` after a 401, when a cached token must not be returned. When nobody
    ///   is signed in, throw rather than return an empty string: the request then fails before
    ///   it is sent, instead of going out without credentials.
    public init(token: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String) {
        self.tokens = TokenSource(fetch: token)
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let token = try await tokens.current()
        let first = try await next(Self.authorize(request, with: token), body, baseURL)
        guard first.0.status == .unauthorized, body?.iterationBehavior != .single else { return first }
        let renewed = try await tokens.replacement(for: token)
        guard renewed != token else { return first }
        return try await next(Self.authorize(request, with: renewed), body, baseURL)
    }

    private static func authorize(_ request: HTTPRequest, with token: String) -> HTTPRequest {
        var request = request
        request.headerFields[.authorization] = "Bearer \(token)"
        return request
    }
}

/// Holds the token closure and the refresh that requests failing together wait on.
///
/// Refreshes are keyed by the token that was rejected. A request that has been refused with token
/// `A` joins a refresh of `A` that is still running, or takes the result of the last one that
/// finished; only when neither exists does it start its own.
actor TokenSource {
    private let fetch: @Sendable (_ forceRefresh: Bool) async throws -> String

    /// The refresh still running, and the token it replaces.
    private var running: (rejected: String, task: Task<String, any Error>)?

    /// The last refresh that finished: the token it replaced and the token it produced.
    private var finished: (rejected: String, renewed: String)?

    init(fetch: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String) {
        self.fetch = fetch
    }

    /// The token for an ordinary request, as the closure returns it.
    nonisolated func current() async throws -> String {
        try await fetch(false)
    }

    /// A token to use in place of one the server rejected.
    func replacement(for rejected: String) async throws -> String {
        if let finished, finished.rejected == rejected { return finished.renewed }
        if let running, running.rejected == rejected { return try await running.task.value }

        let fetch = self.fetch
        let task = Task { try await fetch(true) }
        running = (rejected, task)
        defer { if running?.task == task { running = nil } }
        let renewed = try await task.value
        finished = (rejected, renewed)
        return renewed
    }
}
