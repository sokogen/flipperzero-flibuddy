import Foundation
@testable import FliBuddyCore

/// An in-memory Bambuddy for `Session` tests. Records every call in order and
/// matches tags the way `by-tag` does: the tray UUID first, then the UID.
final class FakeInventory: SpoolInventory, @unchecked Sendable {
    enum Call: Equatable {
        case find(tray: String?, uid: String)
        case update(spoolId: Int, gross: Int)
        case create(NewSpool)
        case link(spoolId: Int, TagLink)
        case delete(spoolId: Int)
        case setUsed(spoolId: Int, grams: Int)
        case archive(spoolId: Int)
        case restore(spoolId: Int)
        case spoolman
        case list
        case catalog
    }

    private let lock = NSLock()
    private var stored: [Spool]
    private var recorded: [Call] = []
    private var nextId = 100
    private var colorMapCount = 0

    var spoolman = false
    var spoolmanError: BambuddyError?
    var findError: BambuddyError?
    var updateError: BambuddyError?
    var createError: BambuddyError?
    var linkError: BambuddyError?
    var deleteError: BambuddyError?
    var setUsedError: BambuddyError?
    var archiveError: BambuddyError?
    var restoreError: BambuddyError?
    var catalogError: BambuddyError?
    var listError: BambuddyError?
    /// What `colorMap` answers; empty by default, so new items carry no colour name.
    var colorMapAnswer = ColorMap(colors: [:], byMaterial: [:])
    var colorMapError: BambuddyError?
    /// Delay before `colorMap` answers, to change the settings mid-load.
    var colorMapDelay: Duration = .zero
    /// `colorMap` calls; kept out of `calls` so call-order tests stay about tags.
    var colorMapLoads: Int { lock.withLock { colorMapCount } }
    var catalogEntries = [CatalogEntry(id: 3, name: "Bambu Lab - Plastic Low Temp", weight: 250)]
    /// Delay before `updateWeight` answers, to overlap concurrent intents.
    var updateDelay: Duration = .zero
    /// Per-weight `updateDelay`, so that one of two overlapping updates ends first.
    var updateDelays: [Int: Duration] = [:]
    /// Delay before `spoolmanEnabled` answers, to change the feed mid-check.
    var spoolmanDelay: Duration = .zero
    /// Answer `updateWeight` without `weight_used`, as a Bambuddy might.
    var omitWeightUsed = false
    /// Runs inside `updateWeight` before it answers, e.g. to move a test clock.
    var onUpdate: (@Sendable () -> Void)?
    /// Runs inside `createSpool` before it answers, e.g. to read the feed mid-create.
    var onCreate: (@Sendable () async -> Void)?
    /// Runs inside `findSpool` before it answers, e.g. to change the settings mid-lookup.
    var onFind: (@Sendable () async -> Void)?
    /// Runs inside `spoolmanEnabled` before it answers, e.g. to edit the settings mid-test.
    var onSpoolman: (@Sendable () async -> Void)?
    /// Runs inside `catalog` before it answers, e.g. to edit the settings mid-load.
    var onCatalog: (@Sendable () async -> Void)?
    /// Runs inside `listSpools` before it answers, e.g. to change the settings mid-list.
    var onList: (@Sendable () async -> Void)?
    /// Runs inside `deleteSpool` before it answers, e.g. to change the settings mid-link.
    var onDelete: (@Sendable () async -> Void)?

    init(spools: [Spool] = []) {
        stored = spools
    }

    var calls: [Call] { lock.withLock { recorded } }
    var spools: [Spool] { lock.withLock { stored } }

    var updates: [Call] { calls.filter { if case .update = $0 { true } else { false } } }
    var creates: [Call] { calls.filter { if case .create = $0 { true } else { false } } }
    /// Every call that changes the inventory, in order.
    var writes: [Call] {
        calls.filter {
            switch $0 {
            case .update, .create, .link, .delete, .setUsed, .archive, .restore: true
            case .find, .spoolman, .list, .catalog: false
            }
        }
    }

    private func record(_ call: Call) {
        lock.withLock { recorded.append(call) }
    }

    /// Archived spools are found too (`include_archived=true`).
    func findSpool(trayUuid: String?, uid: String) async throws -> Spool? {
        record(.find(tray: trayUuid, uid: uid))
        await onFind?()
        if let findError { throw findError }
        return lock.withLock {
            if let trayUuid, let spool = stored.first(where: { $0.trayUuid == trayUuid }) { return spool }
            return stored.first { $0.tagUid == uid }
        }
    }

    func updateWeight(spoolId: Int, gross: Int) async throws -> WeightUpdate {
        record(.update(spoolId: spoolId, gross: gross))
        let delay = updateDelays[gross] ?? updateDelay
        if delay > .zero { try await Task.sleep(for: delay) }
        onUpdate?()
        if let updateError { throw updateError }
        return try lock.withLock {
            guard let index = stored.firstIndex(where: { $0.id == spoolId }) else {
                throw BambuddyError.spoolNotFound(spoolId)
            }
            let net = gross - stored[index].coreWeight
            stored[index].weightUsed = Double(max(0, stored[index].labelWeight - net))
            stored[index].lastScaleWeight = gross
            return WeightUpdate(weightUsed: omitWeightUsed ? nil : stored[index].weightUsed)
        }
    }

    func createSpool(_ spool: NewSpool) async throws -> Spool {
        record(.create(spool))
        await onCreate?()
        if let createError { throw createError }
        return lock.withLock {
            let created = Spool(
                id: nextId, material: spool.material, subtype: spool.subtype, colorName: spool.colorName,
                rgba: spool.rgba, brand: spool.brand, labelWeight: spool.labelWeight,
                coreWeight: spool.coreWeight, coreWeightCatalogId: spool.coreWeightCatalogId,
                weightUsed: 0, tagUid: spool.tagUid, trayUuid: spool.trayUuid, tagType: spool.tagType,
                materialNumber: spool.materialNumber, dataOrigin: spool.dataOrigin
            )
            nextId += 1
            stored.append(created)
            return created
        }
    }

    /// Refuses a tag another spool carries, as Bambuddy does (409 naming the holder).
    func linkTag(spoolId: Int, _ link: TagLink) async throws -> Spool {
        record(.link(spoolId: spoolId, link))
        if let linkError { throw linkError }
        return try lock.withLock {
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

    func deleteSpool(id: Int) async throws {
        record(.delete(spoolId: id))
        await onDelete?()
        if let deleteError { throw deleteError }
        try lock.withLock {
            guard let index = stored.firstIndex(where: { $0.id == id }) else { throw BambuddyError.spoolNotFound(id) }
            stored.remove(at: index)
        }
    }

    /// Answers the spool as Bambuddy's `PATCH` does.
    func setWeightUsed(spoolId: Int, grams: Int) async throws -> Spool {
        record(.setUsed(spoolId: spoolId, grams: grams))
        if let setUsedError { throw setUsedError }
        return try change(spoolId) { $0.weightUsed = Double(grams) }
    }

    func archiveSpool(id: Int) async throws {
        record(.archive(spoolId: id))
        if let archiveError { throw archiveError }
        _ = try change(id) { $0.archivedAt = "2026-10-26T12:00:00" }
    }

    func restoreSpool(id: Int) async throws {
        record(.restore(spoolId: id))
        if let restoreError { throw restoreError }
        _ = try change(id) { $0.archivedAt = nil }
    }

    private func change(_ id: Int, _ edit: (inout Spool) -> Void) throws -> Spool {
        try lock.withLock {
            guard let index = stored.firstIndex(where: { $0.id == id }) else { throw BambuddyError.spoolNotFound(id) }
            edit(&stored[index])
            return stored[index]
        }
    }

    /// Removes the spool without recording a call, as another client would.
    func removeQuietly(_ id: Int) {
        lock.withLock { stored.removeAll { $0.id == id } }
    }

    func spoolmanEnabled() async throws -> Bool {
        record(.spoolman)
        if spoolmanDelay > .zero { try await Task.sleep(for: spoolmanDelay) }
        await onSpoolman?()
        if let spoolmanError { throw spoolmanError }
        return spoolman
    }

    func listSpools() async throws -> [Spool] {
        record(.list)
        await onList?()
        if let listError { throw listError }
        return spools.filter { !$0.isArchived }
    }

    func catalog() async throws -> [CatalogEntry] {
        record(.catalog)
        await onCatalog?()
        if let catalogError { throw catalogError }
        return catalogEntries
    }

    func colorMap() async throws -> ColorMap {
        lock.withLock { colorMapCount += 1 }
        if colorMapDelay > .zero { try await Task.sleep(for: colorMapDelay) }
        if let colorMapError { throw colorMapError }
        return colorMapAnswer
    }
}
