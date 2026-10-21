import SwiftUI

/// A page's row in the Settings sidebar: a rounded highlight when selected, the icon 4 pt in from its edge.
struct SettingsSidebarRow: View {
    static let height: CGFloat = 32
    /// Between two rows: none.
    static let gap: CGFloat = 0
    /// From the highlight's edge to the icon, and to the end of the label.
    static let contentInset: CGFloat = 4
    static let tileSize: CGFloat = 22
    static let glyphSize: CGFloat = 14
    static let tileRadius: CGFloat = 8
    static let fontSize: CGFloat = 13
    static let iconSpacing: CGFloat = 8
    static let hoverOpacity: Double = 0.07
    static let highlightRadius: CGFloat = 8

    let page: SettingsPage
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Self.iconSpacing) {
            SettingsIconTile(
                symbol: page.symbol, tint: page.tint, size: Self.tileSize, glyphSize: Self.glyphSize, cornerRadius: Self.tileRadius)
            Text(page.title)
                .font(.system(size: Self.fontSize, weight: .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.contentInset)
        .frame(height: Self.height)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Self.highlightRadius, style: .continuous).fill(Color.accentColor)
            } else if isHovering {
                RoundedRectangle(cornerRadius: Self.highlightRadius, style: .continuous).fill(.primary.opacity(Self.hoverOpacity))
            }
        }
        .onHover { isHovering = $0 }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
