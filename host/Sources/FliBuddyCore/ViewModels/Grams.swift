import Foundation

/// Grams as the apps show them: the number in the user's format (`1,000`
/// in the US, `1.000` in Germany). Only text on screen and for VoiceOver;
/// the weight fields, the Flipper's lines and Bambuddy get plain digits.
public enum Grams {
    public static func text(_ grams: Int, locale: Locale = .current) -> String {
        grams.formatted(.number.locale(locale))
    }
}
