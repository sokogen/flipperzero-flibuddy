import FliBuddyCore
import SwiftUI

/// A filament colour dot with a hairline `.separator` stroke; a dashed
/// outline when the colour is unknown. Hidden from VoiceOver: the colour
/// name is read instead.
struct SwatchView: View {
    let swatch: Swatch?
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let swatch {
                Circle()
                    .fill(Color(.sRGB, red: swatch.red, green: swatch.green, blue: swatch.blue, opacity: swatch.alpha))
                    .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
            } else {
                Circle()
                    .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3]))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
