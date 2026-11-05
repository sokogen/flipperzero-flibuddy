import FliBuddyCore
import SwiftUI

// The watch has its own capsule style (Watch/).
#if !os(watchOS)
extension View {
    /// The weight entry's Save: tinted, or filled with Increase Contrast
    /// (`SaveEmphasis`). A capsule on iOS; on the Mac the design's 28 pt
    /// push button.
    func saveButtonStyle() -> some View {
        modifier(SaveButtonModifier())
    }
}

private struct SaveButtonModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        switch SaveEmphasis.forContrast(increased: contrast == .increased) {
        case .prominent:
            content.buttonStyle(.borderedProminent).buttonBorderShape(Self.shape)
        case .tinted:
            #if os(macOS)
            // A bordered push button on the Mac does not take the tint.
            content.buttonStyle(MacTintedButtonStyle())
            #else
            content.buttonStyle(.bordered).buttonBorderShape(.capsule)
            #endif
        }
    }

    #if os(macOS)
    private static let shape = ButtonBorderShape.automatic
    #else
    private static let shape = ButtonBorderShape.capsule
    #endif
}

#if os(macOS)
/// The tint at 14 % (24 % in dark mode) with tinted text, 28 pt high: a
/// 14 pt corner on macOS 26, 6 pt on earlier systems (macOS page). The
/// sides are 12, not the page's 16, so the entry stays in its 360 pt column.
private struct MacTintedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MacTintedButton(configuration: configuration)
    }
}

private struct MacTintedButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        configuration.label
            .foregroundStyle(.tint)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(.tint.opacity(colorScheme == .dark ? 0.24 : 0.14), in: shape)
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }

    private var shape: RoundedRectangle {
        if #available(macOS 26, *) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
        }
    }
}
#endif
#endif
