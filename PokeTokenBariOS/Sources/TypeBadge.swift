import SwiftUI
import PokeTokenBarShared

/// Game-colored type chip — the phone counterpart of the Mac's `Badge(tint: .type(...))`, reading
/// the same `PokemonTypeColor` table. White text with a faint shadow keeps light fills (electric,
/// ice, fairy) legible the way the game chart does. Types outside the 18 render gray.
struct TypeBadge: View {
    let type: String

    var body: some View {
        Text(type.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 0.5, y: 0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint, in: Capsule())
    }

    private var tint: Color {
        guard let hex = PokemonTypeColor.hex(for: type) else { return .gray }
        let rgb = PokemonTypeColor.rgb(hex)
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
