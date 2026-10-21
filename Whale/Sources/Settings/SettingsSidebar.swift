import SwiftUI

/// The Settings sidebar: pages in groups, one highlighted. Drawn by hand so rows can sit flush
/// and hover and press can be ours. It does not scroll (the window's minimum height fits every
/// page), so it has no scroll-edge fade over its first row.
struct SettingsSidebar: View {
    /// Spark's sidebar fill: a light tint over the blur, low so the wallpaper still shows through.
    private static let lightColumnColor = Color(red: 242 / 255, green: 242 / 255, blue: 242 / 255)
    private static let columnFillOpacity: Double = 0.15

    @Binding var selection: SettingsPage
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSidebarRow.gap) {
            ForEach(SettingsPage.Group.allCases) { group in
                if let title = group.title {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, SettingsSidebarRow.contentInset)
                        .padding(.top, 14)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(group.pages) { page in
                    Button { selection = page } label: {
                        SettingsSidebarRow(page: page, isSelected: selection == page)
                    }
                    .buttonStyle(SettingsSidebarButtonStyle())
                }
            }
            Spacer(minLength: 0)
            Text(SettingsAppVersion.displayString)
                .font(.footnote.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.leading, SettingsSidebarRow.contentInset)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The same sidebar material and light fill as the library's sidebar.
        .background {
            ZStack {
                SidebarBlur()
                (colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Self.lightColumnColor)
                    .opacity(Self.columnFillOpacity)
            }
            .ignoresSafeArea()
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.downArrow) { move(by: 1) }
    }

    private func move(by offset: Int) -> KeyPress.Result {
        let pages = SettingsPage.allCases
        guard let index = pages.firstIndex(of: selection), pages.indices.contains(index + offset) else { return .handled }
        selection = pages[index + offset]
        return .handled
    }
}
