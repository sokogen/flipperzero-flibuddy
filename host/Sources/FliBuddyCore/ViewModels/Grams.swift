import Foundation

/// Grams as the apps show them: the number in the user's digits, without a
/// grouping separator (`1000`, as the design and the Flipper write it;
/// owner ruling 2026-11-05). Only text on screen and for VoiceOver; the
/// weight fields, the Flipper's lines and Bambuddy get plain digits.
public enum Grams {
    public static func text(_ grams: Int, locale: Locale = .current) -> String {
        grams.formatted(.number.grouping(.never).locale(locale))
    }
}
