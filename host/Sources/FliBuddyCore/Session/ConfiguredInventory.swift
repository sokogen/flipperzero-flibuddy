import Foundation

/// The inventory as one configuration of the session sees it: once the
/// settings change, a write it has not begun is refused with
/// `SessionError.settingsChanged`. Reads pass through; the session refuses
/// their answers on its actor once the action ends (see `writeBegan`).
final class ConfiguredInventory: SpoolInventory, @unchecked Sendable {
    let base: any SpoolInventory
    /// Whether the configuration this inventory belongs to is still the current one.
    let isCurrent: @Sendable () async -> Bool

    private let lock = NSLock()
    private var began = false

    init(base: any SpoolInventory, isCurrent: @escaping @Sendable () async -> Bool) {
        self.base = base
        self.isCurrent = isCurrent
    }

    /// Whether a write passed the check and went to `base`: its Bambuddy may
    /// have changed, even when the settings changed meanwhile.
    var writeBegan: Bool { lock.withLock { began } }

    private func beginWrite() async throws {
        guard await isCurrent() else { throw SessionError.settingsChanged }
        lock.withLock { began = true }
    }

    func findSpool(trayUuid: String?, uid: String) async throws -> Spool? {
        try await base.findSpool(trayUuid: trayUuid, uid: uid)
    }

    func updateWeight(spoolId: Int, gross: Int) async throws -> WeightUpdate {
        try await beginWrite()
        return try await base.updateWeight(spoolId: spoolId, gross: gross)
    }

    func createSpool(_ spool: NewSpool) async throws -> Spool {
        try await beginWrite()
        return try await base.createSpool(spool)
    }

    func linkTag(spoolId: Int, _ link: TagLink) async throws -> Spool {
        try await beginWrite()
        return try await base.linkTag(spoolId: spoolId, link)
    }

    func deleteSpool(id: Int) async throws {
        try await beginWrite()
        try await base.deleteSpool(id: id)
    }

    func setWeightUsed(spoolId: Int, grams: Int, locked: Bool) async throws -> Spool {
        try await beginWrite()
        return try await base.setWeightUsed(spoolId: spoolId, grams: grams, locked: locked)
    }

    func archiveSpool(id: Int) async throws {
        try await beginWrite()
        try await base.archiveSpool(id: id)
    }

    func restoreSpool(id: Int) async throws {
        try await beginWrite()
        try await base.restoreSpool(id: id)
    }

    func spoolmanEnabled() async throws -> Bool {
        try await base.spoolmanEnabled()
    }

    func listSpools(includeArchived: Bool) async throws -> [Spool] {
        try await base.listSpools(includeArchived: includeArchived)
    }

    func catalog() async throws -> [CatalogEntry] {
        try await base.catalog()
    }

    func colorMap() async throws -> ColorMap {
        try await base.colorMap()
    }
}
