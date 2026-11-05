import Foundation

extension Swatch {
    /// A plain English word for the colour, for VoiceOver where neither
    /// Bambuddy nor Bambu's table names it: `white`, `dark gray`, `green`,
    /// `light teal`, `brown`, `translucent dark blue`, `clear`. Never the hex.
    public var colorWord: String {
        if alpha == 0 { return "clear" }
        let word = Self.opaqueWord(red: red, green: green, blue: blue)
        return alpha < 0.75 ? "translucent \(word)" : word
    }

    private static func opaqueWord(red: Double, green: Double, blue: Double) -> String {
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        let chroma = high - low
        let lightness = (high + low) / 2
        let saturation = chroma == 0 ? 0 : chroma / (1 - abs(2 * lightness - 1))
        if saturation < 0.15 || chroma < 0.08 {
            return switch lightness {
            case ..<0.15: "black"
            case 0.9...: "white"
            case ..<0.4: "dark gray"
            case 0.7...: "light gray"
            default: "gray"
            }
        }
        let hue = hueDegrees(red: red, green: green, blue: blue, high: high, chroma: chroma)
        if (8..<45).contains(hue), lightness < 0.4 { return "brown" }
        let name = switch hue {
        case ..<15, 345...: lightness > 0.7 ? "pink" : "red"
        case ..<40: "orange"
        case ..<62: "yellow"
        case ..<165: "green"
        case ..<195: "teal"
        case ..<255: "blue"
        case ..<290: "purple"
        default: "pink"
        }
        if lightness < 0.3 { return "dark \(name)" }
        if lightness > 0.7, name != "pink" { return "light \(name)" }
        return name
    }

    /// 0..<360, red at 0.
    private static func hueDegrees(red: Double, green: Double, blue: Double, high: Double, chroma: Double) -> Double {
        let sector: Double = if high == red {
            (green - blue) / chroma
        } else if high == green {
            (blue - red) / chroma + 2
        } else {
            (red - green) / chroma + 4
        }
        let degrees = sector * 60
        return degrees < 0 ? degrees + 360 : degrees
    }
}
