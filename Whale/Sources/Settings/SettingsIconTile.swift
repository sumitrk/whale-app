import SwiftUI

/// A settings icon: a solid rounded tile, with a white glyph that picks up the tile's tint
/// toward its bottom, like glass over the color. Only the glyph has the glass look.
struct SettingsIconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28
    /// The box the glyph is fitted into. Without it the glyph is a font half the tile's size.
    var glyphSize: CGFloat?
    /// The tile's corner radius; 0.3 of the tile unless given.
    var cornerRadius: CGFloat?

    @ViewBuilder
    private var glyph: some View {
        if let glyphSize {
            // Fitted into a box, so the margin to the tile's edge is known whatever the symbol.
            Image(systemName: symbol).resizable().scaledToFit().fontWeight(.bold).frame(width: glyphSize, height: glyphSize)
        } else {
            Image(systemName: symbol).font(.system(size: size * 0.5, weight: .bold))
        }
    }

    private var radius: CGFloat { cornerRadius ?? size * 0.3 }

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(tint)
            .overlay {
                glyph
                    .foregroundStyle(LinearGradient(colors: [.white, .white.mixed(with: tint, by: 0.5)], startPoint: .top, endPoint: .bottom))
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
