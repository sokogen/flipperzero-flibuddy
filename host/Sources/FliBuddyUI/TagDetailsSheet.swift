import FliBuddyCore
import SwiftUI

// The watch shows the details at the bottom of its row detail (Watch/).
#if !os(watchOS)
/// The technical facts the row leaves out (UID, tray UUID, colour code,
/// filament id, …), one labelled row each; identifiers are monospaced and
/// selectable for copying.
struct TagDetailsSheet: View {
    let details: TagDetails
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(details.title).font(.headline).padding([.horizontal, .top], 20)
            Form {
                ForEach(details.facts) { fact in
                    LabeledContent(fact.label) {
                        Text(fact.value)
                            .font(fact.isIdentifier ? .body.monospaced() : .body)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        #if os(macOS)
        // A sheet on macOS sizes to its content.
        .frame(minWidth: 420)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }
}
#endif
