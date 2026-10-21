import SwiftUI

/// The sidebar row's button: no fade while pressed (the plain style dims the label).
struct SettingsSidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
