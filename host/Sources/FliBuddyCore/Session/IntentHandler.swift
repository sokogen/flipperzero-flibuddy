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
                return Outcome(result: result(intent, ok: true, ["Saved", "\(left) g left"], spool: saved.spool), row: saved)
            } catch SessionError.spoolNotFound(let uid) {
                var row = row
                row.spool = nil
                row.createdSpoolId = nil
                row.status = .unknown(prefill: row.tag.hasPrefill)
                let error = "no spool for tag \(uid)"
                return Outcome(result: result(intent, ok: false, ["Not saved", "Spool not found"], error), row: row)
            }

        case .new:
            var row = row
            guard let newSpool = newSpool(for: row) else {
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
            return Outcome(result: result(intent, ok: true, ["Created", "spool #\(id)"], spool: created.spool), row: created)

        case .full, .empty, .delete:
            do {
                return try await mark(intent, on: row)
            } catch BambuddyError.spoolNotFound(let id) where intent.action != .delete && row.spool?.id == id {
                return try await mark(intent, on: Self.lookingUpAgain(row, spool: id))
            }
        }
    }

    /// Mark as new, Mark as empty or Delete, looking the spool up when the
    /// row has none.
    private func mark(_ intent: Intent, on row: FeedRow) async throws -> Outcome {
        let known: Spool? = if let spool = row.spool { spool } else { try await find(row.tag) }
        guard let spool = known else {
            var row = row
            row.status = .unknown(prefill: row.tag.hasPrefill)
            let lines = [Self.failureLine(intent.action), "Spool not found"]
            return Outcome(result: result(intent, ok: false, lines, "no spool for tag \(row.tag.uid)"), row: row)
        }
        switch intent.action {
        case .full:
            let marked = try await markFull(row, spool, by: .flipper)
            let left = marked.spool?.remaining ?? 0
            return Outcome(
                result: result(intent, ok: true, ["Marked as new", "\(left) g left"], spool: marked.spool), row: marked
            )
        case .empty:
            let marked = try await markEmpty(row, spool, by: .flipper)
            return Outcome(result: result(intent, ok: true, ["Marked as empty", "archived"], spool: marked.spool), row: marked)
        default:
            let deleted = try await delete(row, spool, by: .flipper)
            return Outcome(result: result(intent, ok: true, ["Deleted", "spool #\(spool.id)"]), row: deleted)
        }
    }

    /// The row without its spool, which Bambuddy no longer has (deleted
    /// elsewhere): the next call looks the tag up again.
    private static func lookingUpAgain(_ row: FeedRow, spool id: Int) -> FeedRow {
        Log.notice(.session, "spool gone: id=\(row.scanId) spool=\(id); looking the tag up again")
        var row = row
        row.spool = nil
        row.createdSpoolId = nil
        return row
    }

    /// The first result line when the action fails.
    static func failureLine(_ action: Intent.Action) -> String {
        switch action {
        case .new: "Not created"
        case .delete: "Not deleted"
        case .weigh, .full, .empty, .createOnHost, .linkOnHost: "Not saved"
        }
    }

    /// The spool a tag with material becomes: the tag's data with the
    /// configured core weight and catalog entry; `nil` without material.
    func newSpool(for row: FeedRow) -> NewSpool? {
        NewSpool(
            tag: row.tag, coreWeight: settings.coreWeight, coreWeightCatalogId: settings.catalogEntryId,
            colorName: row.colorName
        )
    }

    /// `create_on_host` / `link_on_host`: mark the row for the host user; no
    /// Bambuddy call, so it works while Bambuddy is unavailable.
    static func flag(_ intent: Intent, on row: FeedRow) -> Outcome {
        var row = row
        row.request = intent.action == .createOnHost ? .create : .link
        return Outcome(result: LookupBuilder.result(id: intent.id, ok: true, lines: ["Flagged on host"]), row: row)
    }

    /// Record a scale weight for the row's spool, looking the spool up when
    /// the row has none yet. A tag no spool carries is created from the tag
    /// first ("Add and weigh"), unless it has no material. The lookup comes
    /// first every time, so a retry after the create went through and the
    /// weight did not weighs that spool instead of creating another. An
    /// archived spool is restored first.
    /// A spool the row knows that Bambuddy no longer has is looked up again
    /// by tag, once.
    func weigh(_ row: FeedRow, grams: Int, mode: Intent.WeightMode, by side: FeedRow.Side) async throws -> FeedRow {
        do {
            return try await weighOnce(row, grams: grams, mode: mode, by: side)
        } catch BambuddyError.spoolNotFound(let id) where row.spool?.id == id {
            return try await weighOnce(Self.lookingUpAgain(row, spool: id), grams: grams, mode: mode, by: side)
        }
    }

    private func weighOnce(_ row: FeedRow, grams: Int, mode: Intent.WeightMode, by side: FeedRow.Side) async throws -> FeedRow {
        var row = row
        let known: Spool? = if let spool = row.spool { spool } else { try await find(row.tag) }
        var spool: Spool
        if let known {
            spool = known
        } else if let newSpool = newSpool(for: row) {
            spool = try await inventory.createSpool(newSpool)
            Log.info(.session, "create for weight: id=\(row.scanId) spool=\(spool.id)")
        } else {
            throw SessionError.spoolNotFound(row.tag.uid)
        }
        if spool.isArchived { spool = try await restore(spool) }
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

    /// Mark as new: restores an archived spool, then sets `weight_used` to 0.
    func markFull(_ row: FeedRow, _ spool: Spool, by side: FeedRow.Side) async throws -> FeedRow {
        let restored = spool.isArchived ? try await restore(spool) : spool
        var updated = try await inventory.setWeightUsed(spoolId: restored.id, grams: 0)
        if spool.isArchived { updated.archived = false }
        return Self.marked(row, updated, .markedNew, by: side)
    }

    /// Mark as empty: sets `weight_used` to the label weight, then archives
    /// the spool (unless it is archived already).
    func markEmpty(_ row: FeedRow, _ spool: Spool, by side: FeedRow.Side) async throws -> FeedRow {
        var updated = try await inventory.setWeightUsed(spoolId: spool.id, grams: spool.labelWeight)
        if !spool.isArchived { try await inventory.archiveSpool(id: spool.id) }
        updated.archived = true
        return Self.marked(row, updated, .markedEmpty, by: side)
    }

    /// Deletes the spool; one already gone counts as deleted. The row keeps
    /// the tag, free for New or Link.
    func delete(_ row: FeedRow, _ spool: Spool, by side: FeedRow.Side) async throws -> FeedRow {
        do {
            try await inventory.deleteSpool(id: spool.id)
        } catch BambuddyError.spoolNotFound(spool.id) {
            // deleted elsewhere
        }
        var row = row
        row.spool = nil
        row.createdSpoolId = nil
        row.weight = nil
        row.status = .deleted
        row.savedBy = side
        row.request = nil
        return row
    }

    private func restore(_ spool: Spool) async throws -> Spool {
        try await inventory.restoreSpool(id: spool.id)
        var spool = spool
        spool.archived = false
        spool.archivedAt = nil
        return spool
    }

    /// A marked spool is no longer a stand-in Link may delete.
    private static func marked(_ row: FeedRow, _ spool: Spool, _ status: FeedRow.Status, by side: FeedRow.Side) -> FeedRow {
        var row = row
        row.spool = spool
        row.createdSpoolId = nil
        row.weight = nil
        row.status = status
        row.savedBy = side
        row.request = nil
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

    private func result(
        _ intent: Intent, ok: Bool, _ lines: [String], _ error: String? = nil, spool: Spool? = nil
    ) -> IntentResult {
        LookupBuilder.result(id: intent.id, ok: ok, lines: lines, error: error, spool: spool)
    }
}
