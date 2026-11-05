import Foundation

/// A Bambuddy call that failed, mapped from the HTTP status where it matters.
public enum BambuddyError: Error, Equatable, Sendable {
    /// The configured base URL is not an http(s) URL with a host.
    case invalidBaseURL(String)
    /// No HTTP response: DNS, connection refused, timeout.
    case network(String)
    /// 401: the API key is wrong or revoked.
    case unauthorized
    /// 403: the API key lacks this permission, e.g. `settings:read`.
    case permissionMissing(String)
    /// 404 for a spool addressed by id.
    case spoolNotFound(Int)
    /// 409 on `link-tag`. Bambuddy 1.2.5.2 does not name the other spool; later
    /// releases do.
    case tagAlreadyLinked(otherSpoolId: Int?)
    /// The client refuses to create an item without `material`.
    case missingMaterial
    /// Any other non-2xx status, with Bambuddy's `detail` text.
    case http(status: Int, message: String)
    /// A 2xx response whose body does not match the expected model.
    case decoding(String)
    /// The https:// connection failed on the server's certificate (self-signed,
    /// unknown root, expired or not yet valid).
    case untrustedCertificate
}

extension BambuddyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let url): "Bambuddy URL must start with http:// or https://: \(url)"
        case .network(let reason): "Bambuddy unreachable: \(reason)"
        case .unauthorized: "Bambuddy rejected the API key"
        case .permissionMissing(let permission): "API key lacks the \(permission) permission"
        case .spoolNotFound(let id): "Spool #\(id) not found in Bambuddy"
        case .tagAlreadyLinked(let other?): "Tag already linked to spool #\(other)"
        case .tagAlreadyLinked(nil): "Tag already linked to another spool"
        case .missingMaterial: "Refusing to create a spool without material"
        case .http(let status, let message): "Bambuddy HTTP \(status): \(message)"
        case .decoding(let reason): "Unexpected Bambuddy response: \(reason)"
        case .untrustedCertificate: "Bambuddy's certificate is not trusted"
        }
    }
}
