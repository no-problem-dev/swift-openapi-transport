# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-09-30

### Added

- `HTTPTransportClientTransport`: a swift-openapi-runtime `ClientTransport` that sends through any
  swift-http-transport `HTTPTransport`. The server URL's path is kept and the request path and query
  are appended to it. A header name that appears more than once is sent as one joined value.
  The request body is collected up to `maxRequestBodyBytes` (16 MiB by default) before sending.
- `isIdempotent`, a closure from the operation ID and the method, sets each request's
  `isIdempotent`, which `RetryingTransport` checks before replaying. `defaultIdempotency` follows
  RFC 9110: GET, HEAD, PUT, DELETE, OPTIONS and TRACE.
- `BearerTokenMiddleware`: sends `Authorization: Bearer <token>` from a
  `@Sendable (_ forceRefresh: Bool) async throws -> String` closure. After a 401 it asks with
  `forceRefresh: true` and resends once; a second 401 is returned as is. It does not resend when
  the refreshed token equals the rejected one, when the request body can be read only once, or for
  any status other than 401. Requests rejected with the same token share one refresh.
- `RequestURLError`, thrown when the server URL and the request path cannot be combined.
- A test that fails if a source re-exports a module, so swift-http-transport's `HTTPRequest` and
  `HTTPResponse` never reach a file that uses swift-http-types.
