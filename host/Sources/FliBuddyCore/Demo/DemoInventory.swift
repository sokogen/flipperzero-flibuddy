import Foundation

/// The demo's Bambuddy: an in-memory inventory in internal mode, seeded with
/// `DemoFixtures.spools`, that takes every write (save weight, New, Link,
/// mark, delete) without a network. Tags match as `by-tag` does: the tray
/// UUID first, then the UID; archived spools are found too.
public final class DemoInventory: SpoolInventory, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Spool]
    private var nextId = 100

    public init(spools: [Spool] = DemoFixtures.spools) {
        stored = spools
    }

    /// Every spool, archived ones included.
    public var spools: [Spool] { lock.withLock { stored } }

    public func findSpool(trayUuid: String?, uid: String) async throws -> Spool? {
        lock.withLock {
            if let trayUuid, let spool = stored.first(where: { $0.trayUuid == trayUuid }) { return spool }
            return stored.first { $0.tagUid == uid }
        }
    }

    public func updateWeight(spoolId: Int, gross: Int) async throws -> WeightUpdate {
        let spool = try change(spoolId) { spool in
            let net = gross - spool.coreWeight
            spool.weightUsed = Double(max(0, spool.labelWeight - net))
            spool.lastScaleWeight = gross
        }
        return WeightUpdate(weightUsed: spool.weightUsed)
    }

    public func createSpool(_ spool: NewSpool) async throws -> Spool {
        lock.withLock {
            let created = Spool(
                id: nextId, material: spool.material, subtype: spool.subtype, colorName: spool.colorName,
                rgba: spool.rgba, brand: spool.brand, labelWeight: spool.labelWeight,
                coreWeight: spool.coreWeight, coreWeightCatalogId: spool.coreWeightCatalogId,
                weightUsed: Double(spool.weightUsed), tagUid: spool.tagUid, trayUuid: spool.trayUuid,
                tagType: spool.tagType, materialNumber: spool.materialNumber, dataOrigin: spool.dataOrigin
            )
            nextId += 1
            stored.append(created)
            return created
        }
    }

    /// Refuses a tag another spool carries, as Bambuddy does.
    public func linkTag(spoolId: Int, _ link: TagLink) async throws -> Spool {
        try lock.withLock {
            guard let index = stored.firstIndex(where: { $0.id == spoolId }) else {
                throw BambuddyError.spoolNotFound(spoolId)
            }
            let holder = stored.first { spool in
                spool.id != spoolId
                    && (spool.tagUid == link.tagUid || (link.trayUuid != nil && spool.trayUuid == link.trayUuid))
            }
            if let holder { throw BambuddyError.tagAlreadyLinked(otherSpoolId: holder.id) }
            stored[index].tagUid = link.tagUid
            stored[index].trayUuid = link.trayUuid
            stored[index].tagType = link.tagType
            return stored[index]
        }
    }

    public func deleteSpool(id: Int) async throws {
        try lock.withLock {
            guard let index = stored.firstIndex(where: { $0.id == id }) else { throw BambuddyError.spoolNotFound(id) }
            stored.remove(at: index)
        }
    }

    public func setWeightUsed(spoolId: Int, grams: Int) async throws -> Spool {
        try change(spoolId) { $0.weightUsed = Double(grams) }
    }

    public func archiveSpool(id: Int) async throws {
        _ = try change(id) { $0.archivedAt = DemoFixtures.archivedAt }
    }

    public func restoreSpool(id: Int) async throws {
        _ = try change(id) {
            $0.archivedAt = nil
            $0.archived = nil
        }
    }

    public func spoolmanEnabled() async throws -> Bool { false }

    /// Active spools, as the Link picker lists them.
    public func listSpools() async throws -> [Spool] {
        spools.filter { !$0.isArchived }
    }

    public func catalog() async throws -> [CatalogEntry] { DemoFixtures.catalog }

    public func colorMap() async throws -> ColorMap { DemoFixtures.colorMap }

    private func change(_ id: Int, _ edit: (inout Spool) -> Void) throws -> Spool {
        try lock.withLock {
            guard let index = stored.firstIndex(where: { $0.id == id }) else { throw BambuddyError.spoolNotFound(id) }
            edit(&stored[index])
            return stored[index]
        }
    }
}
