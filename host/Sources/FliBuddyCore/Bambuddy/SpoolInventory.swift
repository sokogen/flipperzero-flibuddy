import Foundation

/// The Bambuddy calls the session makes. `BambuddyClient` is the real one;
/// tests use an in-memory fake.
public protocol SpoolInventory: Sendable {
    func findSpool(trayUuid: String?, uid: String) async throws -> Spool?
    func updateWeight(spoolId: Int, gross: Int) async throws -> WeightUpdate
    func createSpool(_ spool: NewSpool) async throws -> Spool
    func linkTag(spoolId: Int, _ link: TagLink) async throws -> Spool
    func deleteSpool(id: Int) async throws
    func setWeightUsed(spoolId: Int, grams: Int, locked: Bool) async throws -> Spool
    func archiveSpool(id: Int) async throws
    func restoreSpool(id: Int) async throws
    func spoolmanEnabled() async throws -> Bool
    /// Bambuddy's spools; archived ones only when `includeArchived`.
    func listSpools(includeArchived: Bool) async throws -> [Spool]
    func catalog() async throws -> [CatalogEntry]
    func colorMap() async throws -> ColorMap
}

extension SpoolInventory {
    /// Active (not archived) spools, as the Link picker lists them.
    public func listSpools() async throws -> [Spool] {
        try await listSpools(includeArchived: false)
    }
}

extension BambuddyClient: SpoolInventory {}
