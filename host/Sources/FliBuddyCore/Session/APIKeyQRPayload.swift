import Foundation

/// The base URL and API key in the QR code of Bambuddy's API-key dialog:
/// `bambuddy://config?v=1&url=<encodeURIComponent(origin)>&key=<encodeURIComponent(key)>`
/// (Bambuddy `frontend/src/utils/apiKeyQr.ts`). Only version 1 is accepted.
public struct APIKeyQRPayload: Equatable, Sendable {
    public static let version = "1"

    /// `scheme://host[:port]`, no trailing slash, as `Settings.baseURL` holds it.
    public var baseURL: String
    public var apiKey: String

    public init(baseURL: String, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    public enum ParseError: Error, Equatable, Sendable {
        /// Not a `bambuddy://config` link.
        case notBambuddyConfig
        /// A `v` other than 1.
        case unsupportedVersion(String)
        /// `v`, `url` or `key` is absent or empty.
        case missingField(String)
        /// The field's value has a malformed `%` escape.
        case invalidEncoding(String)
        /// The decoded `url` is not an http(s) URL with a host.
        case invalidBaseURL(String)
    }

    /// Reads a scanned QR code. Fields are split before they are
    /// percent-decoded, so escaped `&`, `=` and `+` in the key survive.
    public static func parse(_ string: String) throws -> APIKeyQRPayload {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = text.range(of: "://"),
              text[..<separator.lowerBound].lowercased() == "bambuddy"
        else { throw ParseError.notBambuddyConfig }
        let rest = text[separator.upperBound...]
        let host = rest.prefix { $0 != "?" }
        guard host.lowercased() == "config" else { throw ParseError.notBambuddyConfig }
        let query = rest.dropFirst(host.count + 1)

        var fields: [String: Substring] = [:]
        for pair in query.split(separator: "&") {
            let name = String(pair.prefix { $0 != "=" })
            if fields[name] == nil { fields[name] = pair.dropFirst(name.count + 1) }
        }
        func field(_ name: String) throws -> String {
            guard let raw = fields[name] else { throw ParseError.missingField(name) }
            guard let value = raw.removingPercentEncoding else { throw ParseError.invalidEncoding(name) }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ParseError.missingField(name) }
            return trimmed
        }

        let version = try field("v")
        guard version == Self.version else { throw ParseError.unsupportedVersion(version) }
        let url = try field("url")
        let key = try field("key")
        return APIKeyQRPayload(baseURL: try normalise(url), apiKey: key)
    }

    /// Scheme, host, port and any path prefix; no credentials, query,
    /// fragment or trailing slash; http(s) with a host, as `BambuddyClient` requires.
    private static func normalise(_ url: String) throws -> String {
        guard var components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty
        else { throw ParseError.invalidBaseURL(url) }
        components.scheme = scheme
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let normalised = components.string, URL(string: normalised) != nil else { throw ParseError.invalidBaseURL(url) }
        return normalised
    }
}

extension APIKeyQRPayload.ParseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notBambuddyConfig: "Not a Bambuddy API key QR code"
        case .unsupportedVersion(let version): "Unsupported Bambuddy QR code version \(version); update FliBuddy"
        case .missingField(let name): "The QR code has no \(name)"
        case .invalidEncoding(let name): "The QR code's \(name) is garbled"
        case .invalidBaseURL(let url): "The QR code's URL is not an http(s) address: \(url)"
        }
    }
}
