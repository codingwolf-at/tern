import Foundation

/// Transport encoding for hook payloads: `tern://claude-hook?v=1&p=<base64url(JSON)>`.
///
/// The payload travels as base64url so paths with spaces, quotes, Unicode or reserved URL
/// characters survive intact without any hand-rolled escaping.
enum ClaudeHookURL {
    /// Debug builds use their own scheme so hooks installed for the real app can never be
    /// routed to a development build (which keeps its state in memory).
    #if DEBUG
    static let scheme = "tern-debug"
    #else
    static let scheme = "tern"
    #endif
    static let host = "claude-hook"
    static let version = "1"
    /// Generous for the allowlisted fields; rejects anything unexpectedly large.
    static let maximumPayloadBytes = 16 * 1024

    enum DecodingError: Error, Equatable {
        case notAHookURL
        case unsupportedVersion
        case missingPayload
        case payloadTooLarge
        case malformedPayload
    }

    static func encode(_ payload: ClaudeHookPayload) throws -> URL {
        let data = try JSONEncoder().encode(payload)
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [
            URLQueryItem(name: "v", value: version),
            URLQueryItem(name: "p", value: base64URLEncoded(data)),
        ]
        guard let url = components.url else { throw DecodingError.malformedPayload }
        return url
    }

    static func isHookURL(_ url: URL) -> Bool {
        url.scheme == scheme && url.host() == host
    }

    static func decode(_ url: URL) throws(DecodingError) -> ClaudeHookPayload {
        guard isHookURL(url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw .notAHookURL
        }
        let items = components.queryItems ?? []
        guard items.first(where: { $0.name == "v" })?.value == version else { throw .unsupportedVersion }
        guard let encoded = items.first(where: { $0.name == "p" })?.value else { throw .missingPayload }
        guard encoded.utf8.count <= maximumPayloadBytes * 4 / 3 + 4 else { throw .payloadTooLarge }
        guard let data = base64URLDecoded(encoded) else { throw .malformedPayload }
        guard data.count <= maximumPayloadBytes else { throw .payloadTooLarge }
        do {
            return try JSONDecoder().decode(ClaudeHookPayload.self, from: data)
        } catch {
            throw .malformedPayload
        }
    }

    static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecoded(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
