import SwiftUI

/// The capsule every Connections and Settings dropdown and import button is drawn with.
struct CapsuleLabel: View {
    let title: String
    var showsChevron = true

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            if showsChevron { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
        }
        .font(.callout)
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.08), in: .capsule)
        .contentShape(.capsule)
    }
}
