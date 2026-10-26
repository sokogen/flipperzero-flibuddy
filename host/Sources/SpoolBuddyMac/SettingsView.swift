import SpoolBuddyCore
import SpoolBuddyUI
import SwiftUI

/// The Settings window. Each time it opens it edits a fresh copy of the saved settings.
struct SettingsView: View {
    let host: HostModel
    @ViewState private var model: SettingsViewModel?

    var body: some View {
        Group {
            if let model {
                SettingsForm(model: model)
            } else {
                ProgressView()
            }
        }
        // The window takes its size from the content; give the placeholder
        // the form's size so the saved window frame never shrinks to the spinner.
        .frame(width: 640)
        .frame(minHeight: 600)
        .onAppear {
            let model = host.makeSettingsViewModel()
            model.refreshPorts()
            self.model = model
            Task { await model.loadCatalog() }
        }
    }
}
