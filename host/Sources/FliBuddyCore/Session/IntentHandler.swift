import Foundation

/// Performs Flipper intents and host edits against Bambuddy, following the
/// weight rules: `gross = net + core_weight` of the spool in question; new items
/// take the core weight and catalog id from the settings.
///
/// Returns the updated row. Bambuddy errors are thrown; refusals that will not
/// change on a retry (unknown spool, no material, already linked) are results.
struct IntentHandler {
    struct Outcome {
        var result: IntentResult
        var row: FeedRow
    }

    let inventory: any SpoolInventory
    let settings: Settings

    func perform(_ intent: Intent, on row: FeedRow) async throws -> Outcome {
        switch intent.action {
        case .createOnHost, .linkOnHost:
            return Self.flag(intent, on: row)

        case .weigh:
            // validate() guarantees grams and mode for weigh.
            guard let grams = intent.grams, let mode = intent.mode else {
                return Outcome(result: result(intent, ok: false, ["Not saved"], "weigh needs grams and mode"), row: row)
            }
            do {
                let saved = try await weigh(row, grams: grams, mode: mode, by: .flipper)
                let left = saved.spool?.remaining ?? 0
                return Outcome(result: result(intent, ok: true, ["Saved", "\(left) g left"]), row: saved)
            } catch SessionError.spoolNotFound(let uid) {
                var row = row
                row.status = .unknown(prefill: row.tag.hasPrefill)
                let error = "no spool for tag \(uid)"
                return Outcome(result: result(intent, ok: false, ["Not saved", "Spool not found"], error), row: row)
            }

        case .new:
            var row = row
            guard let newSpool = NewSpool(
                tag: row.tag, coreWeight: settings.coreWeight, coreWeightCatalogId: settings.catalogEntryId,
                colorName: row.colorName
            ) else {
                let error = "tag carries no material"
                return Outcome(result: result(intent, ok: false, ["Not created", "No material on tag"], error), row: row)
            }
            if let existing = try await find(row.tag) {
                row.spool = existing
                row.status = .awaitingWeight
                let error = "tag already linked to spool \(existing.id)"
                let lines = ["Already in Bambuddy", "spool #\(existing.id)"]
                return Outcome(result: result(intent, ok: false, lines, error), row: row)
            }
            let created = try await create(row, newSpool, by: .flipper)
            let id = created.spool?.id ?? 0
            return Outcome(result: result(intent, ok: true, ["Created", "spool #\(id)"]), row: created)
        }
    }

    /// `create_on_host` / `link_on_host`: mark the row for the host user; no
    /// Bambuddy call, so it works while Bambuddy is unavailable.
    static func flag(_ intent: Intent, on row: FeedRow) -> Outcome {
        var row = row
        row.request = intent.action == .createOnHost ? .create : .link
        return Outcome(result: LookupBuilder.result(id: intent.id, ok: true, lines: ["Flagged on host"]), row: row)
    }

    /// Record a scale weight for the row's spool, looking the spool up when
    /// the row has none yet.
    func weigh(_ row: FeedRow, grams: Int, mode: Intent.WeightMode, by side: FeedRow.Side) async throws -> FeedRow {
        var row = row
        let known: Spool? = if let spool = row.spool { spool } else { try await find(row.tag) }
        guard var spool = known else {
            throw SessionError.spoolNotFound(row.tag.uid)
        }
        let gross = mode == .gross ? grams : WeightMath.grossFromNet(grams, core: spool.coreWeight)
        let update = try await inventory.updateWeight(spoolId: spool.id, gross: gross)
        spool.weightUsed = update.weightUsed
            ?? WeightMath.usedAfterWeighing(gross: gross, label: spool.labelWeight, core: spool.coreWeight)
        spool.lastScaleWeight = gross
        row.spool = spool
        row.status = .saved
        row.weight = FeedRow.Weight(grams: grams, mode: mode)
        row.savedBy = side
        // A spool with a weight is no longer a stand-in Link may delete.
        row.createdSpoolId = nil
        return row
    }

    func create(_ row: FeedRow, _ newSpool: NewSpool, by side: FeedRow.Side) async throws -> FeedRow {
        var row = row
        Self.markCreated(&row, try await inventory.createSpool(newSpool), by: side)
        return row
    }

    static func markCreated(_ row: inout FeedRow, _ spool: Spool, by side: FeedRow.Side) {
        row.spool = spool
        row.createdSpoolId = spool.id
        row.status = .created
        row.savedBy = side
        row.request = nil
    }

    func link(_ row: FeedRow, toSpool spoolId: Int) async throws -> FeedRow {
        var row = row
        row.spool = try await inventory.linkTag(spoolId: spoolId, TagLink(tag: row.tag))
        row.createdSpoolId = nil
        row.status = .awaitingWeight
        row.request = nil
        return row
    }

    /// Deletes the spool created for the row, which frees the tag for a link.
    /// A spool already gone counts as deleted.
    func deleteCreated(_ row: FeedRow) async throws -> FeedRow {
        guard let created = row.createdSpoolId else { return row }
        do {
            try await inventory.deleteSpool(id: created)
        } catch BambuddyError.spoolNotFound(created) {
            // deleted elsewhere: the tag is free already
        } catch SessionError.settingsChanged {
            throw SessionError.settingsChanged
        } catch {
            throw SessionError.createdSpoolKept(spoolId: created, reason: Session.describe(error))
        }
        var row = row
        row.spool = nil
        row.createdSpoolId = nil
        row.status = .unknown(prefill: row.tag.hasPrefill)
        return row
    }

    func find(_ tag: ParsedTag) async throws -> Spool? {
        try await inventory.findSpool(trayUuid: tag.trayUuid, uid: tag.bambuddyTagUid)
    }

    private func result(_ intent: Intent, ok: Bool, _ lines: [String], _ error: String? = nil) -> IntentResult {
        LookupBuilder.result(id: intent.id, ok: ok, lines: lines, error: error)
    }
}
