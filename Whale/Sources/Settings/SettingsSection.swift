import SwiftUI

/// A rounded card of settings rows, with an optional header above and a note below. Rows are
/// separated by hairlines.
struct SettingsSection<Content: View>: View {
    var header: LocalizedStringKey?
    var footer: LocalizedStringKey?
    @ViewBuilder var content: Content
    @Environment(\.displayScale) private var displayScale

    init(_ header: LocalizedStringKey? = nil, footer: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    private var separator: some View {
        Rectangle().fill(.separator).frame(height: 1 / displayScale).padding(.horizontal, 14)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 12)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                if #available(macOS 15, *) {
                    Group(subviews: content) { rows in
                        ForEach(rows) { row in
                            row
                            if row.id != rows.last?.id { separator }
                        }
                    }
                } else {
                    _VariadicView.Tree(SeparatedRows(separator: separator)) { content }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator.opacity(0.5)) }
            if let footer {
                Text(footer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Before `Group(subviews:)` (macOS 15): the same rows with `separator` between them.
private struct SeparatedRows<Separator: View>: _VariadicView_MultiViewRoot {
    var separator: Separator

    func body(children: _VariadicView.Children) -> some View {
        ForEach(children) { row in
            row
            if row.id != children.last?.id { separator }
        }
    }
}
