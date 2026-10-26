import Foundation
import Testing
@testable import SpoolBuddyCore

@Suite("APIKeyQRPayload")
struct APIKeyQRPayloadTests {
    /// What Bambuddy's `buildApiKeyQrPayload(origin, key)` produces.
    private static let scanned = "bambuddy://config?v=1&url=http%3A%2F%2F192.168.1.10%3A8000&key=bb_abc123"

    @Test func parsesTheVersionOnePayload() throws {
        let payload = try APIKeyQRPayload.parse(Self.scanned)
        #expect(payload == APIKeyQRPayload(baseURL: "http://192.168.1.10:8000", apiKey: "bb_abc123"))
    }

    @Test func decodesEveryEscapeInTheKey() throws {
        // encodeURIComponent escapes `=`, `&` and `+`; splitting comes first.
        let payload = try APIKeyQRPayload.parse("bambuddy://config?v=1&url=https%3A%2F%2Fbambuddy.lan&key=a%3Db%26c%2Bd%20e")
        #expect(payload.apiKey == "a=b&c+d e")
        #expect(payload.baseURL == "https://bambuddy.lan")
    }

    @Test func toleratesSurroundingWhitespaceAndCase() throws {
        let payload = try APIKeyQRPayload.parse("  BAMBUDDY://Config?url=HTTP%3A%2F%2F10.0.0.5%3A8000%2F&key=k&v=1\n")
        #expect(payload == APIKeyQRPayload(baseURL: "http://10.0.0.5:8000", apiKey: "k"))
    }

    @Test(arguments: [
        ("http://192.168.1.10:8000/", "http://192.168.1.10:8000"),
        ("https://bambuddy.lan", "https://bambuddy.lan"),
        ("http://user:secret@bambuddy.lan:8000/?a=1#top", "http://bambuddy.lan:8000"),
        ("http://[fd00::1]:8000", "http://[fd00::1]:8000"),
        ("https://example.com/bambuddy/", "https://example.com/bambuddy"),
    ])
    func normalisesTheBaseURL(url: String, expected: String) throws {
        let encoded = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let payload = try APIKeyQRPayload.parse("bambuddy://config?v=1&url=\(encoded)&key=k")
        #expect(payload.baseURL == expected)
    }

    @Test func theFirstOfARepeatedFieldWins() throws {
        let payload = try APIKeyQRPayload.parse("bambuddy://config?v=1&url=http%3A%2F%2Fa.lan&key=one&key=two")
        #expect(payload.apiKey == "one")
    }

    @Test(arguments: [
        "https://bambuddy.lan/config?v=1&url=http%3A%2F%2Fa.lan&key=k",
        "spoolbuddy://config?v=1&url=http%3A%2F%2Fa.lan&key=k",
        "bambuddy://settings?v=1&url=http%3A%2F%2Fa.lan&key=k",
        "bambuddy:config?v=1&url=http%3A%2F%2Fa.lan&key=k",
        "bb_abc123",
        "",
    ])
    func rejectsOtherCodes(text: String) {
        #expect(throws: APIKeyQRPayload.ParseError.notBambuddyConfig) { try APIKeyQRPayload.parse(text) }
    }

    @Test func rejectsOtherVersions() {
        #expect(throws: APIKeyQRPayload.ParseError.unsupportedVersion("2")) {
            try APIKeyQRPayload.parse("bambuddy://config?v=2&url=http%3A%2F%2Fa.lan&key=k")
        }
    }

    @Test(arguments: [
        ("bambuddy://config?v=1&url=http%3A%2F%2Fa.lan", "key"),
        ("bambuddy://config?v=1&url=http%3A%2F%2Fa.lan&key=", "key"),
        ("bambuddy://config?v=1&url=http%3A%2F%2Fa.lan&key=%20%20", "key"),
        ("bambuddy://config?v=1&key=k", "url"),
        ("bambuddy://config?v=1&url=&key=k", "url"),
        ("bambuddy://config?url=http%3A%2F%2Fa.lan&key=k", "v"),
        ("bambuddy://config", "v"),
    ])
    func rejectsMissingOrEmptyFields(text: String, field: String) {
        #expect(throws: APIKeyQRPayload.ParseError.missingField(field)) { try APIKeyQRPayload.parse(text) }
    }

    @Test(arguments: [
        ("bambuddy://config?v=1&url=http%3A%2F%2Fa.lan&key=bb%ZZ", "key"),
        ("bambuddy://config?v=1&url=http%3A%2F%2Fa.lan%&key=k", "url"),
    ])
    func rejectsInvalidPercentEncoding(text: String, field: String) {
        #expect(throws: APIKeyQRPayload.ParseError.invalidEncoding(field)) { try APIKeyQRPayload.parse(text) }
    }

    @Test(arguments: ["ftp%3A%2F%2Fa.lan", "a.lan%3A8000", "http%3A%2F%2F", "not%20a%20url"])
    func rejectsURLsThatAreNotHTTP(encoded: String) throws {
        let url = try #require(encoded.removingPercentEncoding)
        #expect(throws: APIKeyQRPayload.ParseError.invalidBaseURL(url)) {
            try APIKeyQRPayload.parse("bambuddy://config?v=1&url=\(encoded)&key=k")
        }
    }

    @Test func everyErrorHasAMessage() {
        let errors: [APIKeyQRPayload.ParseError] = [
            .notBambuddyConfig, .unsupportedVersion("2"), .missingField("key"), .invalidEncoding("url"),
            .invalidBaseURL("ftp://a"),
        ]
        for error in errors {
            #expect(!(error.errorDescription ?? "").isEmpty)
        }
        #expect(APIKeyQRPayload.ParseError.unsupportedVersion("2").errorDescription?.contains("2") == true)
    }

    @Test func theParsedURLMakesAClient() throws {
        let payload = try APIKeyQRPayload.parse(Self.scanned)
        let settings = Settings(baseURL: payload.baseURL, apiKey: payload.apiKey)
        #expect(settings.isConfigured)
    }
}
