import Foundation
import Testing
@testable import FliBuddyCore

@Suite("Bambuddy errors: a plain sentence, the detail in the hint")
struct ErrorTextTests {
    @Test(arguments: [
        (BambuddyError.network("no answer within 5 s"), "Bambuddy didn't answer",
         "Bambuddy unreachable: no answer within 5 s" as String?),
        (.http(status: 500, message: "boom"), "Bambuddy couldn't make the change", "Bambuddy HTTP 500: boom"),
        (.decoding("bad"), "Bambuddy's answer didn't make sense", "Unexpected Bambuddy response: bad"),
        (.unauthorized, "Bambuddy rejected the API key", nil),
        (.permissionMissing("inventory:write"), "The API key isn't allowed to do this",
         "API key lacks the inventory:write permission"),
        (.spoolNotFound(42), "The spool is no longer in Bambuddy", "Spool #42 not found in Bambuddy"),
        (.tagAlreadyLinked(otherSpoolId: 5), "Another spool already has this tag", "Tag already linked to spool #5"),
        (.missingMaterial, "The tag has no material", "Refusing to create a spool without material"),
        (.untrustedCertificate, "Bambuddy's certificate is not trusted", nil),
        (.invalidBaseURL("nas"), "The Bambuddy address isn't valid", "Bambuddy URL must start with http:// or https://: nas"),
    ])
    func eachBambuddyErrorReadsAsASentence(error: BambuddyError, sentence: String, hint: String?) {
        let text = ErrorText(error)
        #expect(text.sentence == sentence)
        #expect(text.hint == hint)
    }

    @Test func otherErrorsKeepTheirOwnWords() {
        let text = ErrorText(SessionError.invalidWeight(12_000))
        #expect(text.sentence == Session.describe(SessionError.invalidWeight(12_000)))
        #expect(text.hint == nil)
    }

    @Test func aFailedHostSaveShowsTheSentenceAndHintsTheDetail() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = Session(settings: testSettings, inventory: inventory)
        let model = await FeedViewModel(session: session, settings: testSettings)
        _ = await session.handleScan(try fixtureScan())
        await model.apply(await session.snapshot)
        let id = try #require(await model.items.first?.id)
        inventory.updateError = .http(status: 500, message: "boom")

        await model.setWeightText("700", for: id)
        await model.save(id)

        #expect(await model.error(for: id) == "Bambuddy couldn't make the change")
        #expect(await model.errorHint(for: id) == "Bambuddy HTTP 500: boom")
    }

    @Test func aRowThatFailedOnTheFlipperShowsTheSentence() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = Session(settings: testSettings, inventory: inventory)
        _ = await session.handleScan(try fixtureScan())
        inventory.updateError = .network("no answer within 5 s")
        _ = await session.handleIntent(try fixtureIntent("intent_weigh"))

        let row = try #require(await session.rows.first)
        let item = FeedItem(row)
        #expect(item.statusText == "Error: Bambuddy didn't answer")
        #expect(item.errorHint == "Bambuddy unreachable: no answer within 5 s")
        #expect(item.isError)
    }

    @Test func aCancellationIsNoErrorText() {
        #expect(Session.describe(CancellationError()) == "cancelled")
        #expect(ErrorText(CancellationError()).sentence == "Stopped before Bambuddy answered")
        #expect(!Session.describe(CancellationError()).contains("CancellationError"))
    }

    @Test func aCancelledCheckKeepsThePreviousState() async throws {
        let inventory = FakeInventory()
        let session = Session(settings: testSettings, inventory: inventory)
        #expect(await session.checkBambuddy() == .ready)

        inventory.spoolmanCancels = true
        #expect(await session.checkBambuddy() == .ready)
        #expect(await session.bambuddy == .ready)
    }

    @Test func aCancelledHostActionShowsNoError() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = Session(settings: testSettings, inventory: inventory)
        let model = await FeedViewModel(session: session, settings: testSettings)
        _ = await session.handleScan(try fixtureScan())
        await model.apply(await session.snapshot)
        let id = try #require(await model.items.first?.id)
        inventory.updateCancels = true

        await model.setWeightText("700", for: id)
        #expect(!(await model.save(id)))

        #expect(await model.error(for: id) == nil)
        #expect(await model.haptic == nil)
        // The row is back where it was, not "Error: Cancelled".
        let row = try #require(await session.rows.first)
        #expect(row.status == .awaitingWeight)
        #expect(row.failure == nil)
        #expect(FeedItem(row).statusText == "Enter weight")
    }

    @Test func aCancelledFlipperWeighLeavesTheRowAsItWas() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        let session = Session(settings: testSettings, inventory: inventory)
        _ = await session.handleScan(try fixtureScan())
        inventory.updateCancels = true

        let result = await session.handleIntent(try weighIntent(grams: 734, mode: .gross))

        #expect(!result.ok)
        let row = try #require(await session.rows.first)
        #expect(row.status == .awaitingWeight)
        #expect(!FeedItem(row).isError)
    }

    @Test func aCancelledLookupSaysSoInAPlainSentence() async throws {
        let inventory = FakeInventory(spools: [knownSpool()])
        inventory.findCancels = true
        let session = Session(settings: testSettings, inventory: inventory)

        _ = await session.handleScan(try fixtureScan())

        let row = try #require(await session.rows.first)
        #expect(FeedItem(row).statusText == "Error: Stopped before Bambuddy answered")
        #expect(!FeedItem(row).statusText.contains("Cancelled"))
    }
}
