import Foundation
import Testing

/// swift-http-types and swift-http-transport declare types with the same names. A client module
/// that imports this package must not receive swift-http-transport's names along with it, or its
/// own `HTTPRequest` and `HTTPResponse` stop resolving.
@Suite("Source policy")
struct SourcePolicyTests {
    private static let sourceDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/OpenAPIHTTPTransport")

    private static func sources() throws -> [(name: String, text: String)] {
        let files = FileManager.default.enumerator(at: sourceDirectory, includingPropertiesForKeys: nil)?
            .allObjects as? [URL] ?? []
        return try files.filter { $0.pathExtension == "swift" }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test("The sources are where the test looks")
    func findsSources() throws {
        let names = try Self.sources().map(\.name)
        #expect(names.contains("BearerTokenMiddleware.swift"))
        #expect(names.contains("HTTPTransportClientTransport.swift"))
    }

    @Test("No module is re-exported")
    func noReexports() throws {
        let hits = try Self.sources().filter { $0.text.contains("@_exported") }.map(\.name)
        #expect(hits.isEmpty, "\(hits)")
    }
}
