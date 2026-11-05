import Foundation

/// How the weight entry's Save looks (Spec page, "Weight entry"): a tinted
/// button, not a filled one, because the weight is the focus. Its blue text
/// on the tinted fill reaches only about 3.4:1, so with Increase Contrast
/// Save becomes the filled button.
public enum SaveEmphasis: Equatable, Sendable {
    /// `.bordered` on iOS: the tint at low opacity with tinted text.
    case tinted
    /// `.borderedProminent`: the tint filled, white text.
    case prominent

    /// `increased`: the system's Increase Contrast is on
    /// (`colorSchemeContrast == .increased`).
    public static func forContrast(increased: Bool) -> SaveEmphasis {
        increased ? .prominent : .tinted
    }
}
