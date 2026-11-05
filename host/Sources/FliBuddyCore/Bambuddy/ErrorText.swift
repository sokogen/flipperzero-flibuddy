import Foundation

/// A failure as a row shows it: a plain sentence, and the technical detail
/// (the status, Bambuddy's own message, the system reason) for the hint.
/// Logs and the Flipper keep `Session.describe(_:)`.
public struct ErrorText: Equatable, Sendable {
    public let sentence: String
    /// `nil` when the sentence already says it all.
    public let hint: String?

    public init(sentence: String, hint: String? = nil) {
        self.sentence = sentence
        self.hint = hint
    }

    public init(_ error: any Error) {
        let detail = Session.describe(error)
        let sentence = Self.sentence(error) ?? detail
        self.init(sentence: sentence, hint: sentence == detail ? nil : detail)
    }

    private static func sentence(_ error: any Error) -> String? {
        guard let error = error as? BambuddyError else { return nil }
        return switch error {
        case .invalidBaseURL: "The Bambuddy address isn't valid"
        case .network: "Bambuddy didn't answer"
        case .unauthorized: "Bambuddy rejected the API key"
        case .permissionMissing: "The API key isn't allowed to do this"
        case .spoolNotFound: "The spool is no longer in Bambuddy"
        case .tagAlreadyLinked: "Another spool already has this tag"
        case .missingMaterial: "The tag has no material"
        case .http: "Bambuddy couldn't make the change"
        case .decoding: "Bambuddy's answer didn't make sense"
        case .untrustedCertificate: "Bambuddy's certificate is not trusted"
        }
    }
}
