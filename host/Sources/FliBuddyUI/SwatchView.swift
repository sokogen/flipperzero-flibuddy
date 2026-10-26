import FliBuddyCore
import SwiftUI

/// A filament colour dot; dashed when the colour is unknown.
struct SwatchView: View {
    let swatch: Swatch?

    var body: some View {
        if let swatch {
            Circle()
                .fill(Color(.sRGB, red: swatch.red, green: swatch.green, blue: swatch.blue, opacity: swatch.alpha))
                .overlay(Circle().strokeBorder(.secondary.opacity(0.4)))
                .frame(width: 24, height: 24)
        } else {
            Circle()
                .strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3]))
                .frame(width: 24, height: 24)
        }
    }
}
