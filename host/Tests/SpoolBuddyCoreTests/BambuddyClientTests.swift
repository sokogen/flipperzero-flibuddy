import Foundation
import Testing
@testable import SpoolBuddyCore

/// A `SpoolResponse` from Bambuddy 1.2.5.2, trimmed to the fields the host reads
/// plus a few it ignores.
func spoolJSON(
    id: Int = 42, material: String = "PLA", labelWeight: Int = 1000, coreWeight: Int = 250,
    weightUsed: Double = 516, lastScaleWeight: Int? = 734
) -> String {
    """
    {"id":\(id),"material":"\(material)","subtype":"PLA Basic","color_name":"Jade White",
     "rgba":"FFFFFFFF","brand":"Bambu Lab","label_weight":\(labelWeight),
     "core_weight":\(coreWeight),"core_weight_catalog_id":3,"weight_used":\(weightUsed),
     "last_scale_weight":\(lastScaleWeight.map(String.init) ?? "null"),
     "tag_uid":"04A1B2C3","tray_uuid":"A1B2C3D4E5F60718293A4B5C6D7E8F90",
     "tag_type":"bambulab","data_origin":"flipper","note":null,
     "created_at":"2026-10-25T12:00:00","updated_at":"2026-10-25T12:00:00","k_profiles":[]}
    """
}

private let trayA = "A1B2C3D4E5F60718293A4B5C6D7E8F90"
private let trayB = "0123456789ABCDEF0123456789ABCDEF"

@Suite("BambuddyClient")
struct BambuddyClientTests {
    // MARK: findSpool

    @Test func findSpoolTriesTheTrayUuidThenTheUID() async throws {
        let server = StubServer { _ in .json(404, #"{"detail":"Spool not found"}"#) }
        let spool = try await server.client().findSpool(trayUuid: trayA, uid: "04A1B2C3")
        #expect(spool == nil)
        let requests = server.requests
        #expect(requests.map(\.path) == Array(repeating: "/api/v1/inventory/spools/by-tag", count: 2))
        #expect(requests.map(\.method) == ["GET", "GET"])
        #expect(requests.map(\.query) == [["tray_uuid": trayA], ["tag_uid": "04A1B2C3"]])
    }

    @Test func findSpoolStopsAtTheTrayUuidMatch() async throws {
        let server = StubServer { request in
            request.query["tray_uuid"] == trayA ? .json(200, spoolJSON()) : .json(404, #"{"detail":"Spool not found"}"#)
        }
        let spool = try #require(try await server.client().findSpool(trayUuid: trayA, uid: "04A1B2C3"))
        #expect(spool.id == 42)
        #expect(server.requests.count == 1)
    }

    @Test func findSpoolFallsBackToTheUID() async throws {
        let server = StubServer { request in
            request.query["tag_uid"] == "04A1B2C3" ? .json(200, spoolJSON()) : .json(404, #"{"detail":"Spool not found"}"#)
        }
        let spool = try #require(try await server.client().findSpool(trayUuid: trayB, uid: "04A1B2C3"))
        #expect(spool.id == 42)
        #expect(server.requests.map(\.query) == [["tray_uuid": trayB], ["tag_uid": "04A1B2C3"]])
    }

    @Test func findSpoolWithoutATrayUuidQueriesTheUID() async throws {
        let server = StubServer { _ in .json(200, spoolJSON()) }
        let spool = try await server.client().findSpool(trayUuid: nil, uid: "04112233445566")
        #expect(spool?.id == 42)
        #expect(server.requests.map(\.query) == [["tag_uid": "04112233445566"]])
    }

    @Test func findSpoolDecodesTheSpool() async throws {
        let server = StubServer { _ in .json(200, spoolJSON()) }
        let spool = try #require(try await server.client().findSpool(trayUuid: trayA, uid: "04A1B2C3"))
        #expect(spool == Spool(
            id: 42, material: "PLA", subtype: "PLA Basic", colorName: "Jade White", rgba: "FFFFFFFF",
            brand: "Bambu Lab", labelWeight: 1000, coreWeight: 250, coreWeightCatalogId: 3,
            weightUsed: 516, lastScaleWeight: 734, tagUid: "04A1B2C3", trayUuid: trayA,
            tagType: "bambulab", dataOrigin: "flipper", note: nil
        ))
        #expect(spool.remaining == 484)
    }

    @Test func findSpoolReportsServerErrors() async throws {
        let server = StubServer { _ in .json(500, #"{"detail":"boom"}"#) }
        await #expect(throws: BambuddyError.http(status: 500, message: "boom")) {
            try await server.client().findSpool(trayUuid: trayA, uid: "04A1B2C3")
        }
        #expect(server.requests.count == 1)
    }

    @Test func findSpoolMaps403ToInventoryRead() async throws {
        let server = StubServer { _ in .json(403, #"{"detail":"Missing permission"}"#) }
        await #expect(throws: BambuddyError.permissionMissing("inventory:read")) {
            try await server.client().findSpool(trayUuid: nil, uid: "04A1B2C3")
        }
    }

    // MARK: updateWeight

    @Test func updateWeightPostsGrossGrams() async throws {
        let server = StubServer { _ in .json(200, #"{"status":"ok","weight_used":516.0}"#) }
        let update = try await server.client().updateWeight(spoolId: 42, gross: 734)
        #expect(update == WeightUpdate(weightUsed: 516))
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v1/spoolbuddy/scale/update-spool-weight")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.json["spool_id"] as? Int == 42)
        #expect(request.json["weight_grams"] as? Int == 734)
        #expect(request.json.count == 2)
    }

    @Test func updateWeightWithoutWeightUsedDecodes() async throws {
        let server = StubServer { _ in .json(200, #"{"status":"ok"}"#) }
        let update = try await server.client().updateWeight(spoolId: 42, gross: 734)
        #expect(update == WeightUpdate(weightUsed: nil))
    }

    @Test(arguments: [
        (#"{"detail":"Spool not found"}"#, "Spool not found"),
        (#"{"detail":{"code":"tag_conflict","message":"Tag in use"}}"#, "Tag in use"),
        (#"{"detail":{"code":"tag_conflict"}}"#, "tag_conflict"),
        (#"{"detail":[{"loc":["body","material"],"msg":"field required"},{"msg":"bad"}]}"#,
         "body.material: field required; bad"),
        (#"{"detail":42}"#, #"{"detail":42}"#),
        ("Bad Gateway", "Bad Gateway"),
    ])
    func errorDetailsAreReadable(body: String, expected: String) {
        #expect(BambuddyClient.detail(Data(body.utf8)) == expected)
    }

    @Test func errorDetailsAreCapped() {
        let long = String(repeating: "x", count: 500)
        #expect(BambuddyClient.detail(Data(long.utf8)).count == BambuddyClient.maxMessage)
    }

    @Test func updateWeightMaps403ToInventoryUpdate() async throws {
        let server = StubServer { _ in .json(403, #"{"detail":"Missing permission"}"#) }
        await #expect(throws: BambuddyError.permissionMissing("inventory:update")) {
            try await server.client().updateWeight(spoolId: 42, gross: 734)
        }
    }

    @Test func updateWeightMaps404ToSpoolNotFound() async throws {
        let server = StubServer { _ in .json(404, #"{"detail":"Spool not found"}"#) }
        await #expect(throws: BambuddyError.spoolNotFound(42)) {
            try await server.client().updateWeight(spoolId: 42, gross: 734)
        }
    }

    // MARK: createSpool

    @Test func createSpoolSendsTheFullItem() async throws {
        let server = StubServer { _ in .json(200, spoolJSON(id: 77, weightUsed: 0, lastScaleWeight: nil)) }
        let new = NewSpool(
            material: "PLA", subtype: "PLA Basic", colorName: "#FFFFFFFF", rgba: "FFFFFFFF",
            brand: "Bambu Lab", labelWeight: 1000, coreWeight: 250, coreWeightCatalogId: 3,
            nozzleTempMin: 190, nozzleTempMax: 230,
            tagUid: "04A1B2C3", trayUuid: trayA, tagType: "bambulab"
        )
        let created = try await server.client().createSpool(new)
        #expect(created.id == 77)
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v1/inventory/spools")
        let body = request.json
        #expect(body["material"] as? String == "PLA")
        #expect(body["subtype"] as? String == "PLA Basic")
        #expect(body["color_name"] as? String == "#FFFFFFFF")
        #expect(body["rgba"] as? String == "FFFFFFFF")
        #expect(body["brand"] as? String == "Bambu Lab")
        #expect(body["label_weight"] as? Int == 1000)
        #expect(body["core_weight"] as? Int == 250)
        #expect(body["core_weight_catalog_id"] as? Int == 3)
        #expect(body["weight_used"] as? Int == 0)
        #expect(body["nozzle_temp_min"] as? Int == 190)
        #expect(body["nozzle_temp_max"] as? Int == 230)
        #expect(body["tag_uid"] as? String == "04A1B2C3")
        #expect(body["tray_uuid"] as? String == trayA)
        #expect(body["tag_type"] as? String == "bambulab")
        #expect(body["data_origin"] as? String == "flipper")
        #expect(body.count == 15)
    }

    @Test func createSpoolOmitsAbsentFields() async throws {
        let server = StubServer { _ in .json(200, spoolJSON(id: 78)) }
        let new = NewSpool(material: "PETG", labelWeight: 1000, coreWeight: 216, tagUid: "04112233445566", tagType: "ntag")
        _ = try await server.client().createSpool(new)
        let body = try #require(server.requests.first).json
        #expect(Set(body.keys) == [
            "material", "label_weight", "core_weight", "weight_used", "tag_uid", "tag_type", "data_origin",
        ])
    }

    @Test func createSpoolRefusesAnItemWithoutMaterial() async throws {
        let server = StubServer { _ in .json(200, spoolJSON()) }
        for material in ["", "  "] {
            await #expect(throws: BambuddyError.missingMaterial) {
                try await server.client().createSpool(NewSpool(material: material, labelWeight: 1000, coreWeight: 250))
            }
        }
        #expect(server.requests.isEmpty)
    }

    @Test func createSpoolReportsValidationErrors() async throws {
        let detail = #"{"detail":[{"loc":["body","rgba"],"msg":"String should match pattern","type":"string_pattern_mismatch"}]}"#
        let server = StubServer { _ in .json(422, detail) }
        await #expect(throws: BambuddyError.http(status: 422, message: "body.rgba: String should match pattern")) {
            try await server.client().createSpool(NewSpool(material: "PLA", rgba: "nope", labelWeight: 1000, coreWeight: 250))
        }
    }

    // MARK: NewSpool from a parsed tag

    @Test func newSpoolFromABambuTag() throws {
        let tag = TagParser.parse(try TagFixtures.bambu())
        let new = try #require(NewSpool(tag: tag, coreWeight: 250, coreWeightCatalogId: 3))
        #expect(new.material == tag.material)
        #expect(new.subtype == tag.detailedType)
        #expect(new.rgba == tag.rgba)
        #expect(new.colorName == tag.rgba.map { "#\($0)" })
        #expect(new.brand == "Bambu Lab")
        #expect(new.labelWeight == tag.labelWeight)
        #expect(new.coreWeight == 250)
        #expect(new.coreWeightCatalogId == 3)
        #expect(new.weightUsed == 0)
        #expect(new.nozzleTempMin == tag.nozzleMin)
        #expect(new.nozzleTempMax == tag.nozzleMax)
        #expect(new.tagUid == "5A3C9E2100000100")
        #expect(new.trayUuid == tag.trayUuid)
        #expect(new.tagType == "bambulab")
        #expect(new.dataOrigin == "flipper")
    }

    @Test func newSpoolFallsBackTo1000GramLabel() {
        let tag = ParsedTag(kind: .bambu, uid: "04A1B2C3", material: "PLA")
        let new = NewSpool(tag: tag, coreWeight: 250, coreWeightCatalogId: nil)
        #expect(new?.labelWeight == 1000)
        #expect(new?.trayUuid == nil)
        #expect(new?.coreWeightCatalogId == nil)
    }

    @Test func newSpoolNeedsMaterial() throws {
        #expect(NewSpool(tag: TagParser.parse(try TagFixtures.ntag()), coreWeight: 250, coreWeightCatalogId: nil) == nil)
        #expect(NewSpool(tag: TagParser.parse(try TagFixtures.bambu(missing: [0])), coreWeight: 250, coreWeightCatalogId: nil) == nil)
    }

    // MARK: linkTag

    @Test func linkTagPatchesTheSpool() async throws {
        let server = StubServer { _ in .json(200, spoolJSON(id: 9)) }
        let link = TagLink(tagUid: "04A1B2C3", trayUuid: trayA, tagType: "bambulab")
        let linked = try await server.client().linkTag(spoolId: 9, link)
        #expect(linked.id == 9)
        let request = try #require(server.requests.first)
        #expect(request.method == "PATCH")
        #expect(request.path == "/api/v1/inventory/spools/9/link-tag")
        #expect(request.json["tag_uid"] as? String == "04A1B2C3")
        #expect(request.json["tray_uuid"] as? String == trayA)
        #expect(request.json["tag_type"] as? String == "bambulab")
        #expect(request.json["data_origin"] as? String == "flipper")
        #expect(request.json.count == 4)
    }

    @Test func linkTagFromAParsedTag() throws {
        let tag = TagParser.parse(try TagFixtures.bambu())
        #expect(TagLink(tag: tag) == TagLink(tagUid: "5A3C9E2100000100", trayUuid: tag.trayUuid, tagType: "bambulab"))
        let ntag = TagParser.parse(try TagFixtures.ntag())
        #expect(TagLink(tag: ntag) == TagLink(tagUid: ntag.uid, trayUuid: nil, tagType: "ntag"))
    }

    @Test func createAndLinkCarryBlock9OfTheRealDump() throws {
        let tag = TagParser.parse(try TagFixtures.bambuReal())
        let tray = "F1C8FDF0BC1643C0B37189ADB0687992"
        #expect(NewSpool(tag: tag, coreWeight: 250, coreWeightCatalogId: nil)?.trayUuid == tray)
        #expect(TagLink(tag: tag).trayUuid == tray)
    }

    // MARK: AMS tag UID form on the wire

    @Test func findSpoolQueriesTheAmsFormOfTheRealDump() async throws {
        let tag = TagParser.parse(try TagFixtures.bambuReal())
        let server = StubServer { _ in .json(404, #"{"detail":"Spool not found"}"#) }
        _ = try await server.client().findSpool(trayUuid: tag.trayUuid, uid: tag.bambuddyTagUid)
        #expect(server.requests.map(\.query) == [
            ["tray_uuid": "F1C8FDF0BC1643C0B37189ADB0687992"], ["tag_uid": "7EF1AB0400000100"],
        ])
    }

    @Test func createAndLinkSendTheAmsFormOfTheRealDump() async throws {
        let tag = TagParser.parse(try TagFixtures.bambuReal())
        let server = StubServer { _ in .json(200, spoolJSON()) }
        let client = try server.client()
        _ = try await client.createSpool(try #require(NewSpool(tag: tag, coreWeight: 250, coreWeightCatalogId: nil)))
        _ = try await client.linkTag(spoolId: 42, TagLink(tag: tag))
        #expect(server.requests.map(\.json).map { $0["tag_uid"] as? String } == ["7EF1AB0400000100", "7EF1AB0400000100"])
    }

    @Test func createAndLinkSendAnNtagUidAsRead() async throws {
        let tag = TagParser.parse(try TagFixtures.ntag())
        let server = StubServer { _ in .json(200, spoolJSON()) }
        let client = try server.client()
        var form = NewSpoolForm(tag: tag, settings: Settings(catalogEntryId: nil, coreWeight: 250))
        form.material = "PETG"
        _ = try await client.createSpool(try #require(form.newSpool))
        _ = try await client.linkTag(spoolId: 42, TagLink(tag: tag))
        #expect(server.requests.map(\.json).map { $0["tag_uid"] as? String } == ["04112233445566", "04112233445566"])
    }

    @Test func linkTagMaps409WithAHolderToTagAlreadyLinked() async throws {
        // Bambuddy after 1.2.5.2 (#3110) names the spool that carries the tag.
        let detail = #"{"detail":{"code":"tag_already_linked","message":"Tag UID is already linked to spool 5","spool_id":5,"field":"tag_uid"}}"#
        let server = StubServer { _ in .json(409, detail) }
        await #expect(throws: BambuddyError.tagAlreadyLinked(otherSpoolId: 5)) {
            try await server.client().linkTag(spoolId: 9, TagLink(tagUid: "04A1B2C3", trayUuid: nil, tagType: "bambulab"))
        }
    }

    @Test func linkTagMaps409WithoutAHolderToTagAlreadyLinked() async throws {
        // Bambuddy 1.2.5.2 answers with a plain string.
        let server = StubServer { _ in .json(409, #"{"detail":"Tag UID already linked to another active spool"}"#) }
        await #expect(throws: BambuddyError.tagAlreadyLinked(otherSpoolId: nil)) {
            try await server.client().linkTag(spoolId: 9, TagLink(tagUid: "04A1B2C3", trayUuid: nil, tagType: "bambulab"))
        }
    }

    // MARK: listSpools, spool, catalog

    @Test func listSpoolsDecodesTheInventory() async throws {
        let server = StubServer { _ in .json(200, "[\(spoolJSON(id: 1)),\(spoolJSON(id: 2, material: "PETG"))]") }
        let spools = try await server.client().listSpools()
        #expect(spools.map(\.id) == [1, 2])
        #expect(spools.map(\.material) == ["PLA", "PETG"])
        #expect(server.requests.first?.path == "/api/v1/inventory/spools")
        #expect(server.requests.first?.method == "GET")
    }

    @Test func spoolByIdReadsOneSpool() async throws {
        let server = StubServer { _ in .json(200, spoolJSON(id: 42)) }
        #expect(try await server.client().spool(id: 42).id == 42)
        #expect(server.requests.first?.path == "/api/v1/inventory/spools/42")
    }

    @Test func spoolByIdMaps404ToSpoolNotFound() async throws {
        let server = StubServer { _ in .json(404, #"{"detail":"Spool not found"}"#) }
        await #expect(throws: BambuddyError.spoolNotFound(42)) { try await server.client().spool(id: 42) }
    }

    @Test func catalogDecodesEntries() async throws {
        let body = #"[{"id":1,"name":"Bambu Lab - Plastic High Temp","weight":216,"is_default":true},{"id":3,"name":"Bambu Lab - Plastic Low Temp","weight":250,"is_default":true}]"#
        let server = StubServer { _ in .json(200, body) }
        let catalog = try await server.client().catalog()
        #expect(catalog == [
            CatalogEntry(id: 1, name: "Bambu Lab - Plastic High Temp", weight: 216),
            CatalogEntry(id: 3, name: "Bambu Lab - Plastic Low Temp", weight: 250),
        ])
        #expect(server.requests.first?.path == "/api/v1/inventory/catalog")
    }

    @Test func undecodableBodiesAreReported() async throws {
        let server = StubServer { _ in .json(200, #"{"not":"a list"}"#) }
        await #expect {
            try await server.client().catalog()
        } throws: { error in
            if case BambuddyError.decoding = error { return true }
            return false
        }
    }

    // MARK: spoolmanEnabled

    @Test(arguments: [
        (#""true""#, true), (#""True""#, true), (#""false""#, false), ("true", true), ("false", false),
    ])
    func spoolmanEnabledReadsTheSetting(value: String, expected: Bool) async throws {
        let server = StubServer { _ in
            .json(200, #"{"spoolman_enabled":\#(value),"spoolman_url":"","spoolman_sync_mode":"auto"}"#)
        }
        #expect(try await server.client().spoolmanEnabled() == expected)
        #expect(server.requests.first?.path == "/api/v1/settings/spoolman")
    }

    @Test func spoolmanEnabledMaps403ToSettingsRead() async throws {
        let server = StubServer { _ in .json(403, #"{"detail":"Missing permission: settings:read"}"#) }
        await #expect(throws: BambuddyError.permissionMissing("settings:read")) {
            try await server.client().spoolmanEnabled()
        }
    }

    // MARK: authentication and transport

    @Test func everyRequestSendsTheAPIKey() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/api/v1/inventory/spools"), ("GET", "/api/v1/inventory/catalog"): .json(200, "[]")
            case (_, "/api/v1/settings/spoolman"): .json(200, #"{"spoolman_enabled":"false"}"#)
            case (_, "/api/v1/spoolbuddy/scale/update-spool-weight"): .json(200, #"{"status":"ok","weight_used":0}"#)
            default: .json(200, spoolJSON())
            }
        }
        let client = try server.client(apiKey: "bb_secret")
        _ = try await client.findSpool(trayUuid: trayA, uid: "04A1B2C3")
        _ = try await client.spool(id: 42)
        _ = try await client.updateWeight(spoolId: 42, gross: 700)
        _ = try await client.createSpool(NewSpool(material: "PLA", labelWeight: 1000, coreWeight: 250))
        _ = try await client.linkTag(spoolId: 42, TagLink(tagUid: "04A1B2C3", trayUuid: nil, tagType: "ntag"))
        _ = try await client.listSpools()
        _ = try await client.catalog()
        _ = try await client.spoolmanEnabled()
        #expect(server.requests.count == 8)
        #expect(server.requests.allSatisfy { $0.headers["X-API-Key"] == "bb_secret" })
        #expect(server.requests.allSatisfy { $0.headers["Accept"] == "application/json" })
    }

    @Test func badKeyIsUnauthorized() async throws {
        let server = StubServer { _ in .json(401, #"{"detail":"Invalid API key"}"#) }
        await #expect(throws: BambuddyError.unauthorized) { try await server.client().listSpools() }
    }

    @Test func baseURLWithPathAndTrailingSlashIsJoined() async throws {
        let server = StubServer { _ in .json(200, "[]") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let base = server.baseURL.appendingPathComponent("bambuddy/")
        let client = try BambuddyClient(baseURL: base, apiKey: "bb_test", session: URLSession(configuration: configuration))
        _ = try await client.catalog()
        #expect(server.requests.first?.path == "/bambuddy/api/v1/inventory/catalog")
    }

    @Test func baseURLMustBeHTTP() {
        for text in ["ftp://nas.local", "nas.local:8000", "file:///tmp"] {
            #expect(throws: BambuddyError.invalidBaseURL(text)) {
                try BambuddyClient(baseURL: URL(string: text)!, apiKey: "bb_test")
            }
        }
    }

    @Test func networkFailuresAreReported() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingURLProtocol.self]
        let client = try BambuddyClient(
            baseURL: URL(string: "http://unreachable.test:8000")!, apiKey: "bb_test",
            session: URLSession(configuration: configuration)
        )
        await #expect {
            try await client.listSpools()
        } throws: { error in
            if case BambuddyError.network = error { return true }
            return false
        }
    }

    @Test func errorsHaveReadableDescriptions() {
        let cases: [(BambuddyError, String)] = [
            (.invalidBaseURL("nas"), "Bambuddy URL must start with http:// or https://: nas"),
            (.network("timed out"), "Bambuddy unreachable: timed out"),
            (.unauthorized, "Bambuddy rejected the API key"),
            (.permissionMissing("settings:read"), "API key lacks the settings:read permission"),
            (.spoolNotFound(42), "Spool #42 not found in Bambuddy"),
            (.tagAlreadyLinked(otherSpoolId: 5), "Tag already linked to spool #5"),
            (.tagAlreadyLinked(otherSpoolId: nil), "Tag already linked to another spool"),
            (.missingMaterial, "Refusing to create a spool without material"),
            (.http(status: 500, message: "boom"), "Bambuddy HTTP 500: boom"),
            (.decoding("bad"), "Unexpected Bambuddy response: bad"),
        ]
        for (error, text) in cases {
            #expect(error.errorDescription == text)
        }
    }
}

/// Fails every load, as a dead network would.
final class FailingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)) }
    override func stopLoading() {}
}
