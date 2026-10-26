import SwiftUI

/// SwiftUI's `State` property wrapper under another name.
///
/// The macOS 27 SDK also declares `@State` as a macro implemented in the
/// `SwiftUIMacros` compiler plugin, which only Xcode ships: with the Command
/// Line Tools every `@State` fails with "plugin for module 'SwiftUIMacros' not
/// found". The alias names the property wrapper struct, which needs no plugin.
/// Use `@ViewState` instead of `@State` in this target.
typealias ViewState<Value> = SwiftUI.State<Value>
