import Foundation

/// The Bambuddy calls the session makes. `BambuddyClient` is the real one;
/// tests use an in-memory fake.
public protocol SpoolInventory: Sendable {
    func findSpool(trayUuid: String?, uid: String) async throws -> Spool?
    func updateWeight(spoolId: Int, gross: Int) async throws -> WeightUpdate
    func createSpool(_ spool: NewSpool) async throws -> Spool
    func linkTag(spoolId: Int, _ link: TagLink) async throws -> Spool
    func spoolmanEnabled() async throws -> Bool
    func listSpools() async throws -> [Spool]
    func catalog() async throws -> [CatalogEntry]
}

extension BambuddyClient: SpoolInventory {}
