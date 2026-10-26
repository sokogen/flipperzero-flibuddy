import Foundation
@testable import SpoolBuddyCore

/// An in-memory Bambuddy for `Session` tests. Records every call in order and
/// matches tags the way `by-tag` does: tray UUID candidates first, then the UID.
final class FakeInventory: SpoolInventory, @unchecked Sendable {
    enum Call: Equatable {
        case find(trays: [String], uid: String)
        case update(spoolId: Int, gross: Int)
        case create(NewSpool)
        case link(spoolId: Int, TagLink)
        case spoolman
        case list
        case catalog
    }

    private let lock = NSLock()
    private var stored: [Spool]
    private var recorded: [Call] = []
    private var nextId = 100

    var spoolman = false
    var spoolmanError: BambuddyError?
    var findError: BambuddyError?
    var updateError: BambuddyError?
    var linkError: BambuddyError?
    /// Delay before `updateWeight` answers, to overlap concurrent intents.
    var updateDelay: Duration = .zero

    init(spools: [Spool] = []) {
        stored = spools
    }

    var calls: [Call] { lock.withLock { recorded } }
    var spools: [Spool] { lock.withLock { stored } }

    var updates: [Call] { calls.filter { if case .update = $0 { true } else { false } } }
    var creates: [Call] { calls.filter { if case .create = $0 { true } else { false } } }

    private func record(_ call: Call) {
        lock.withLock { recorded.append(call) }
    }

    func findSpool(trayCandidates: [String], uid: String) async throws -> Spool? {
        record(.find(trays: trayCandidates, uid: uid))
        if let findError { throw findError }
        return lock.withLock {
            for tray in trayCandidates {
                if let spool = stored.first(where: { $0.trayUuid == tray }) { return spool }
            }
            return stored.first { $0.tagUid == uid }
        }
    }

    func updateWeight(spoolId: Int, gross: Int) async throws -> WeightUpdate {
        record(.update(spoolId: spoolId, gross: gross))
        if updateDelay > .zero { try await Task.sleep(for: updateDelay) }
        if let updateError { throw updateError }
        return try lock.withLock {
            guard let index = stored.firstIndex(where: { $0.id == spoolId }) else {
                throw BambuddyError.spoolNotFound(spoolId)
            }
            let net = gross - stored[index].coreWeight
            stored[index].weightUsed = Double(max(0, stored[index].labelWeight - net))
            stored[index].lastScaleWeight = gross
            return WeightUpdate(weightUsed: stored[index].weightUsed)
        }
    }

    func createSpool(_ spool: NewSpool) async throws -> Spool {
        record(.create(spool))
        return lock.withLock {
            let created = Spool(
                id: nextId, material: spool.material, subtype: spool.subtype, colorName: spool.colorName,
                rgba: spool.rgba, brand: spool.brand, labelWeight: spool.labelWeight,
                coreWeight: spool.coreWeight, coreWeightCatalogId: spool.coreWeightCatalogId,
                weightUsed: 0, tagUid: spool.tagUid, trayUuid: spool.trayUuid, tagType: spool.tagType,
                dataOrigin: spool.dataOrigin
            )
            nextId += 1
            stored.append(created)
            return created
        }
    }

    func linkTag(spoolId: Int, _ link: TagLink) async throws -> Spool {
        record(.link(spoolId: spoolId, link))
        if let linkError { throw linkError }
        return try lock.withLock {
            guard let index = stored.firstIndex(where: { $0.id == spoolId }) else {
                throw BambuddyError.spoolNotFound(spoolId)
            }
            stored[index].tagUid = link.tagUid
            stored[index].trayUuid = link.trayUuid
            stored[index].tagType = link.tagType
            return stored[index]
        }
    }

    func spoolmanEnabled() async throws -> Bool {
        record(.spoolman)
        if let spoolmanError { throw spoolmanError }
        return spoolman
    }

    func listSpools() async throws -> [Spool] {
        record(.list)
        return spools
    }

    func catalog() async throws -> [CatalogEntry] {
        record(.catalog)
        return [CatalogEntry(id: 3, name: "Bambu Lab - Plastic Low Temp", weight: 250)]
    }
}
