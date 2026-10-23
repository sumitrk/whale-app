import SwiftUI

/// Rule-based Clean Up: on or off, its style, lists and email layout, and a field to try it.
struct CleanUpSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var sample = ""

    var body: some View {
        SettingsPageLayout(title: "Clean up") {
            SettingsSection(
                footer: "Takes out stutters and fillers, keeps the correction when you change your mind (“Friday, no wait, Thursday”), and follows “new line”, “new paragraph” and “scratch that”. Runs on your Mac in under a millisecond."
            ) {
                SettingsToggleRow(
                    "Clean up what I say",
                    icon: SettingsRowIcon("wand.and.stars", .settingsTeal),
                    isOn: $store.cleanUpEnabled
                )
            }

            if store.cleanUpEnabled {
                SettingsSection("Style", footer: LocalizedStringKey(store.cleanUpStyle.example)) {
                    SettingsPickerRow(
                        "Style",
                        icon: SettingsRowIcon("textformat", .settingsIndigo),
                        selection: $store.cleanUpStyle,
                        choices: CleanUpStyle.allCases.map { .option($0.title, $0) }
                    )
                    SettingsToggleRow(
                        "Numbered lists",
                        subtitle: "“First, … second, …” becomes a list.",
                        icon: SettingsRowIcon("list.number", .settingsBlue),
                        isOn: $store.cleanUpLists
                    )
                    SettingsToggleRow(
                        "Email layout in mail apps",
                        subtitle: "The greeting and sign-off get their own lines.",
                        icon: SettingsRowIcon("envelope.fill", .settingsOrange),
                        isOn: $store.cleanUpEmailLayout
                    )
                }

                SettingsSection("Try it") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Type something the way you’d say it", text: $sample, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...6)
                        if !sample.isEmpty {
                            Text(verbatim: cleanedSample)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
        .animation(.snappy, value: store.cleanUpEnabled)
    }

    private var cleanedSample: String {
        RuleCleanUp.clean(sample, style: store.cleanUpStyle, allowLists: store.cleanUpLists, context: .general)
    }
}
