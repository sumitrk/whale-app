import SwiftUI

/// A settings page: the large title over a scrolling stack of sections.
struct SettingsPageLayout<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(title)
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                content
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}
