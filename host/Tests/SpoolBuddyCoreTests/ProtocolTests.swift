import Foundation
import Testing
@testable import SpoolBuddyCore

enum Fixtures {
    static let root: URL = {
        guard let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            fatalError("Fixtures resource missing; see host/README.md")
        }
        return url
    }()

    static func messages() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: root.appendingPathComponent("messages"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func message(_ name: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent("messages/\(name).json"))
    }

    static var validNames: [String] {
        (try? messages().map { $0.deletingPathExtension().lastPathComponent }.filter { !$0.hasPrefix("invalid_") }) ?? []
    }

    static var invalidNames: [String] {
        (try? messages().map { $0.deletingPathExtension().lastPathComponent }.filter { $0.hasPrefix("invalid_") }) ?? []
    }
}

/// Decodes a JSON object literal after patching it, for negative cases.
private func decodePatched(_ name: String, _ patch: (inout [String: Any]) -> Void) throws -> Message {
    var object = try JSONSerialization.jsonObject(with: Fixtures.message(name)) as! [String: Any]
    patch(&object)
    return try Message.decode(line: JSONSerialization.data(withJSONObject: object))
}

@Suite struct MessageFixtureTests {
    @Test func fixturesAreFound() throws {
        #expect(Fixtures.validNames.count >= 13)
        #expect(Fixtures.invalidNames.count >= 2)
    }

    @Test(arguments: Fixtures.validNames)
    func validFixtureRoundTrips(name: String) throws {
        let decoded = try Message.decode(line: Fixtures.message(name))
        let line = try decoded.encodedLine()
        #expect(line.last == 0x0A)
        #expect(!line.dropLast().contains(0x0A))
        #expect(try Message.decode(line: line) == decoded)
    }

    @Test(arguments: Fixtures.validNames)
    func validFixtureDecodesToTypeNamedByFile(name: String) throws {
        let decoded = try Message.decode(line: Fixtures.message(name))
        let prefix = String(name.prefix { $0 != "_" })
        #expect(decoded.type == prefix)
    }

    @Test(arguments: Fixtures.invalidNames)
    func invalidFixtureFailsToDecode(name: String) throws {
        #expect(throws: ProtocolError.self) { try Message.decode(line: Fixtures.message(name)) }
    }

    @Test func encodedLineMatchesFixtureAsJSON() throws {
        let line = try Message.decode(line: Fixtures.message("lookup_found")).encodedLine()
        let encoded = try JSONSerialization.jsonObject(with: line) as! NSDictionary
        let fixture = try JSONSerialization.jsonObject(with: Fixtures.message("lookup_found")) as! NSDictionary
        #expect(encoded == fixture)
        let text = String(decoding: line, as: UTF8.self)
        #expect(!text.contains("\": ") && !text.contains(", \"") && !text.contains("{ "))
    }

    @Test func mfcTagEncodesLikeTheFixture() throws {
        let line = try Message.decode(line: Fixtures.message("scan_mfc")).encodedLine()
        let encoded = try JSONSerialization.jsonObject(with: line) as! NSDictionary
        let fixture = try JSONSerialization.jsonObject(with: Fixtures.message("scan_mfc")) as! NSDictionary
        #expect(encoded == fixture)
    }
}

@Suite struct MessageDecodingTests {
    @Test func scanMfcFields() throws {
        guard case .scan(let scan) = try Message.decode(line: Fixtures.message("scan_mfc")) else {
            Issue.record("not a scan"); return
        }
        #expect(scan.scanId == "s-000012")
        #expect(scan.tag.type == .mfc)
        #expect(scan.tag.uid == "5A3C9E21")
        #expect(scan.tag.sak == 8)
        #expect(scan.tag.atqa == "0400")
        #expect(scan.tag.missing == [7])
        #expect(scan.tag.blocks[2]?.prefix(3) == [0x50, 0x4C, 0x41])
        #expect(scan.tag.blocks[28] == nil)
        #expect(scan.tag.blocks.values.allSatisfy { $0.count == 16 })
        #expect(scan.tag.pages.isEmpty)
    }

    @Test func scanMfcWithEverySectorMissingKeepsAnEmptyBlocksObject() throws {
        guard case .scan(let scan) = try Message.decode(line: Fixtures.message("scan_mfc_unreadable")) else {
            Issue.record("not a scan"); return
        }
        #expect(scan.tag.blocks.isEmpty)
        #expect(scan.tag.missing == Array(0...15))
        let object = try JSONSerialization.jsonObject(with: Message.scan(scan).encodedLine()) as! [String: Any]
        let tag = object["tag"] as! [String: Any]
        #expect(tag["blocks"] as? [String: String] == [:])
        #expect(TagParser.parse(scan.tag).trayUuidCandidates.isEmpty)
        #expect(TagParser.parse(scan.tag).material == nil)
    }

    @Test func scanNtagFields() throws {
        guard case .scan(let scan) = try Message.decode(line: Fixtures.message("scan_ntag")) else {
            Issue.record("not a scan"); return
        }
        #expect(scan.tag.type == .ntag)
        #expect(scan.tag.uid == "04112233445566")
        #expect(scan.tag.pages.count == 135)
        #expect(scan.tag.pages[0] == [0x04, 0x11, 0x22, 0xBF])
        #expect(scan.tag.blocks.isEmpty)
        #expect(scan.tag.missing.isEmpty)
    }

    @Test func intentWeighFields() throws {
        guard case .intent(let intent) = try Message.decode(line: Fixtures.message("intent_weigh")) else {
            Issue.record("not an intent"); return
        }
        #expect(intent.id == "i-000003")
        #expect(intent.scanId == "s-000012")
        #expect(intent.action == .weigh)
        #expect(intent.grams == 734)
        #expect(intent.mode == .gross)
        #expect(intent.tag.uid == "5A3C9E21")
    }

    @Test func intentActionsDecode() throws {
        let actions = try ["intent_new", "intent_create_on_host", "intent_link_on_host"].map { name -> Intent.Action in
            guard case .intent(let intent) = try Message.decode(line: Fixtures.message(name)) else { throw ProtocolError.invalid(name) }
            return intent.action
        }
        #expect(actions == [.new, .createOnHost, .linkOnHost])
    }

    @Test func lookupAndResultFields() throws {
        guard case .lookup(let lookup) = try Message.decode(line: Fixtures.message("lookup_found")) else {
            Issue.record("not a lookup"); return
        }
        #expect(lookup.status == .found)
        #expect(lookup.spoolId == 42)
        #expect(lookup.lines.count == 4)
        #expect(lookup.defaults == Lookup.Defaults(gross: 734, label: 1000, core: 250))

        guard case .result(let result) = try Message.decode(line: Fixtures.message("result_error")) else {
            Issue.record("not a result"); return
        }
        #expect(result.ok == false)
        #expect(result.error == "spool 42 not found")
    }

    @Test func helloSides() throws {
        #expect(try Message.decode(line: Fixtures.message("hello_flipper")) == .hello(Hello(app: "spoolbuddy-fap/0.1.0", fw: "1.5.1")))
        #expect(try Message.decode(line: Fixtures.message("hello_host")) == .hello(Hello(app: "spoolbuddy-mac/0.1.0", os: "macOS 26.0")))
    }

    @Test func acceptsWhitespaceAndAnyKeyOrder() throws {
        let message = try Message.decode(line: #"{ "v" : 1 , "t" : "result", "id":"i-1","ok":true,"lines":[] }"#)
        #expect(message == .result(IntentResult(id: "i-1", ok: true, lines: [])))
    }

    @Test func unknownTypeIsReportedSeparately() throws {
        #expect(throws: ProtocolError.unknownType("ping")) { try Message.decode(line: #"{"t":"ping","v":1}"#) }
    }

    @Test func otherVersionIsRejected() throws {
        #expect(throws: ProtocolError.unsupportedVersion(2)) {
            try decodePatched("result_ok") { $0["v"] = 2 }
        }
    }

    @Test func notJSONIsMalformed() {
        #expect(throws: ProtocolError.self) { try Message.decode(line: "not json") }
        #expect(throws: ProtocolError.self) { try Message.decode(line: "[1,2]") }
    }

    @Test func schemaConditionalsAreEnforced() {
        // hello needs exactly one of fw / os
        #expect(throws: ProtocolError.self) { try decodePatched("hello_flipper") { $0["os"] = "macOS" } }
        #expect(throws: ProtocolError.self) { try decodePatched("hello_flipper") { $0["fw"] = nil } }
        // weigh needs grams and mode
        #expect(throws: ProtocolError.self) { try decodePatched("intent_weigh") { $0["grams"] = nil } }
        #expect(throws: ProtocolError.self) { try decodePatched("intent_weigh") { $0["mode"] = nil } }
        #expect(throws: ProtocolError.self) { try decodePatched("intent_weigh") { $0["grams"] = 10000 } }
        #expect(throws: ProtocolError.self) { try decodePatched("intent_weigh") { $0["mode"] = "tare" } }
        // found needs spool_id, error needs error
        #expect(throws: ProtocolError.self) { try decodePatched("lookup_found") { $0["spool_id"] = nil } }
        #expect(throws: ProtocolError.self) { try decodePatched("lookup_found") { $0["spool_id"] = 0 } }
        #expect(throws: ProtocolError.self) { try decodePatched("lookup_error") { $0["error"] = nil } }
        // result ok:false needs error
        #expect(throws: ProtocolError.self) { try decodePatched("result_error") { $0["error"] = nil } }
        // lines: at most 4, each at most 40 characters
        #expect(throws: ProtocolError.self) { try decodePatched("result_ok") { $0["lines"] = ["1", "2", "3", "4", "5"] } }
        #expect(throws: ProtocolError.self) { try decodePatched("result_ok") { $0["lines"] = [String(repeating: "x", count: 41)] } }
        // ids
        #expect(throws: ProtocolError.self) { try decodePatched("result_ok") { $0["id"] = "" } }
        #expect(throws: ProtocolError.self) { try decodePatched("result_ok") { $0["id"] = "has space" } }
        #expect(throws: ProtocolError.self) { try decodePatched("result_ok") { $0["id"] = String(repeating: "a", count: 33) } }
    }

    @Test func tagRulesAreEnforced() {
        func patchTag(_ name: String, _ patch: @escaping (inout [String: Any]) -> Void) throws -> Message {
            try decodePatched(name) { object in
                var tag = object["tag"] as! [String: Any]
                patch(&tag)
                object["tag"] = tag
            }
        }
        #expect(throws: ProtocolError.self) { try patchTag("scan_mfc") { $0["blocks"] = nil } }
        #expect(throws: ProtocolError.self) { try patchTag("scan_mfc") { $0["pages"] = ["0": "00000000"] } }
        #expect(throws: ProtocolError.self) { try patchTag("scan_mfc") { $0["blocks"] = ["64": String(repeating: "0", count: 32)] } }
        #expect(throws: ProtocolError.self) { try patchTag("scan_mfc") { $0["blocks"] = ["1": String(repeating: "0", count: 30)] } }
        #expect(throws: ProtocolError.self) { try patchTag("scan_mfc") { $0["blocks"] = ["1": String(repeating: "a", count: 32)] } }
        #expect(throws: ProtocolError.self) { try patchTag("scan_mfc") { $0["blocks"] = ["01": String(repeating: "0", count: 32)] } }
        #expect(throws: ProtocolError.self) { try patchTag("scan_mfc") { $0["missing"] = [16] } }
        #expect(throws: ProtocolError.self) { try patchTag("scan_mfc") { $0["missing"] = [7, 7] } }
        #expect(throws: ProtocolError.self) { try patchTag("scan_mfc") { $0["uid"] = "5A3C9E" } }
        #expect(throws: ProtocolError.self) { try patchTag("scan_mfc") { $0["uid"] = "5a3c9e21" } }
        #expect(throws: ProtocolError.self) { try patchTag("scan_mfc") { $0["atqa"] = "04" } }
        #expect(throws: ProtocolError.self) { try patchTag("scan_mfc") { $0["sak"] = 256 } }
        #expect(throws: ProtocolError.self) { try patchTag("scan_mfc") { $0["type"] = "iso15693" } }
        #expect(throws: ProtocolError.self) { try patchTag("scan_ntag") { $0["blocks"] = ["1": String(repeating: "0", count: 32)] } }
        #expect(throws: ProtocolError.self) { try patchTag("scan_ntag") { $0["missing"] = [Int]() } }
        #expect(throws: ProtocolError.self) { try patchTag("scan_ntag") { $0["pages"] = ["231": "00000000"] } }
        #expect(throws: ProtocolError.self) { try patchTag("scan_ntag") { $0["pages"] = ["0": "0000"] } }
    }
}

@Suite struct MessageEncodingTests {
    @Test func encodesTypeVersionAndSnakeCaseKeys() throws {
        let line = try Message.lookup(Lookup(scanId: "s-1", status: .unknown, prefill: true, lines: ["PLA"],
                                             defaults: .init(label: 1000, core: 250))).encodedLine()
        let object = try JSONSerialization.jsonObject(with: line) as! [String: Any]
        #expect(object["t"] as? String == "lookup")
        #expect(object["v"] as? Int == 1)
        #expect(object["scan_id"] as? String == "s-1")
        #expect(object["status"] as? String == "unknown")
        #expect(object["prefill"] as? Bool == true)
        #expect(object["spool_id"] == nil)
        #expect(object["error"] == nil)
        #expect((object["defaults"] as? [String: Int]) == ["label": 1000, "core": 250])
    }

    @Test func refusesToEncodeAnInvalidMessage() {
        #expect(throws: ProtocolError.self) {
            try Message.result(IntentResult(id: "i-1", ok: false, lines: [])).encodedLine()
        }
        #expect(throws: ProtocolError.self) {
            try Message.lookup(Lookup(scanId: "s-1", status: .found, lines: [])).encodedLine()
        }
    }

    @Test func refusesToEncodeAnOverLongLine() throws {
        guard case .scan(var scan) = try Message.decode(line: Fixtures.message("scan_ntag")) else {
            Issue.record("not a scan"); return
        }
        // The largest valid message, a full NTAG216 dump, fits; nothing valid reaches
        // the limit, so the limit check itself is exercised directly.
        scan.tag.pages = Dictionary(uniqueKeysWithValues: (0...230).map { ($0, [UInt8](repeating: 0xAB, count: 4)) })
        #expect(try Message.scan(scan).encodedLine().count < Message.maxLineBytes)
        #expect(throws: ProtocolError.lineTooLong(Message.maxLineBytes + 1)) {
            try Message.checkLineLength(Data(count: Message.maxLineBytes + 1))
        }
        try Message.checkLineLength(Data(count: Message.maxLineBytes))
    }

    @Test func tagEncodesUppercaseHexAndOmitsEmptyFields() throws {
        let tag = TagDump(type: .ntag, uid: "04112233445566", sak: 0, atqa: "0044", pages: [0: [0xde, 0xad, 0xbe, 0xef]])
        let line = try Message.scan(Scan(scanId: "s-2", tag: tag)).encodedLine()
        let object = try JSONSerialization.jsonObject(with: line) as! [String: Any]
        let encodedTag = object["tag"] as! [String: Any]
        #expect(encodedTag["pages"] as? [String: String] == ["0": "DEADBEEF"])
        #expect(encodedTag["blocks"] == nil)
        #expect(encodedTag["missing"] == nil)
    }
}
