import SwiftUI
import PokeTokenBarShared

/// The 18 main-series types, keyed by PokeAPI's canonical lowercase English name.
enum PokemonType: String, CaseIterable {
    case normal, fire, water, electric, grass, ice, fighting, poison, ground,
         flying, psychic, bug, rock, ghost, dragon, dark, steel, fairy

    init?(apiName: String) { self.init(rawValue: apiName.lowercased()) }

    /// Classic type-chart colors — the shared table, which the iPhone's type chips also read, so the
    /// two apps cannot drift. Every case has a row (`PokemonTypeColorTests` pins it).
    var hex: UInt32 { PokemonTypeColor.table[rawValue] ?? 0x888888 }

    var color: Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}

/// What a `Badge` is colored by.
enum BadgeTint {
    /// nil = a PokeAPI type outside the 18 (stellar, shadow, unknown) → neutral gray.
    case type(PokemonType?)
    case rarity(Rarity?)
    case accent, orange, secondary

    var color: Color {
        switch self {
        case .type(let type): type?.color ?? .gray
        case .rarity(let rarity): rarityColor(rarity)
        case .accent: .accentColor
        case .orange: .orange
        case .secondary: .secondary
        }
    }
}

/// Small capsule label shared by rarity, type and status pills.
/// `.solid` = white text on the tint (rarity, type); `.tinted` = tint text on a faint tint (RAISING, boosts).
@MainActor
struct Badge<Label: View>: View {
    enum Style { case solid, tinted }

    let tint: BadgeTint
    var style: Style = .solid
    var size: CGFloat = 8
    var horizontalPadding: CGFloat = 5
    var verticalPadding: CGFloat = 1
    @ViewBuilder var label: Label

    var body: some View {
        label
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(style == .solid ? Color.white : tint.color)
            // Light type fills (electric, ice, fairy…) keep white text legible the way the game chart does.
            .shadow(color: isType ? .black.opacity(0.35) : .clear, radius: 0.5, y: 0.5)
            .padding(.horizontal, horizontalPadding).padding(.vertical, verticalPadding)
            .background(style == .solid ? tint.color : tint.color.opacity(0.14), in: Capsule())
    }

    private var isType: Bool { if case .type = tint { true } else { false } }
}

extension Badge where Label == Text {
    init(_ text: String, tint: BadgeTint, style: Style = .solid, size: CGFloat = 8) {
        self.init(tint: tint, style: style, size: size) { Text(text) }
    }
}

/// A species' type row — one `Badge` per type, with the localized type name.
@MainActor
struct TypeBadges: View {
    let types: [String]
    let language: AppLanguage
    var size: CGFloat = 8
    var horizontalPadding: CGFloat = 5
    var verticalPadding: CGFloat = 1

    var body: some View {
        HStack(spacing: 5) {
            ForEach(types, id: \.self) { type in
                Badge(tint: .type(PokemonType(apiName: type)), size: size,
                      horizontalPadding: horizontalPadding, verticalPadding: verticalPadding) {
                    PokemonNameLabel(.type, type, language: language).textCase(.uppercase)
                }
            }
        }
    }
}
