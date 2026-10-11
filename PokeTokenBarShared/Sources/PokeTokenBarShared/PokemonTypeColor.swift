import Foundation

/// Classic type-chart colors for the 18 main-series types, keyed by PokeAPI's canonical lowercase
/// English name. One table for the Mac's `PokemonType` badge and the phone's type chips, so the two
/// cannot drift. Types outside the 18 (stellar, shadow, unknown) have no entry; callers show gray.
public enum PokemonTypeColor {
    public static let table: [String: UInt32] = [
        "normal": 0xAAAA99, "fire": 0xFF4422, "water": 0x3399FF, "electric": 0xFFCC33,
        "grass": 0x77CC55, "ice": 0x66CCFF, "fighting": 0xBB5544, "poison": 0xAA5599,
        "ground": 0xDDBB55, "flying": 0x8899FF, "psychic": 0xFF5599, "bug": 0xAABB22,
        "rock": 0xBBAA66, "ghost": 0x6666BB, "dragon": 0x7766EE, "dark": 0x775544,
        "steel": 0xAAAABB, "fairy": 0xEE99EE,
    ]

    /// Case-insensitive lookup; nil for a type outside the 18.
    public static func hex(for apiName: String) -> UInt32? {
        table[apiName.lowercased()]
    }

    /// sRGB components in 0...1 for `hex`.
    public static func rgb(_ hex: UInt32) -> (red: Double, green: Double, blue: Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
}
