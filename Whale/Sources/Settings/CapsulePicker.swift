import SwiftUI

/// One line of a `CapsulePicker`: a choice, or a divider between groups.
enum CapsuleChoice<Value: Hashable>: Identifiable {
    case option(String, Value)
    case divider(Int)

    var id: String {
        switch self {
        case .option(let title, _): title
        case .divider(let index): "divider-\(index)"
        }
    }
}

/// A dropdown drawn as the capsule the import controls use: it shows the chosen title and opens a
/// menu of the choices, a checkmark on the current one.
struct CapsulePicker<Value: Hashable>: View {
    let label: LocalizedStringKey
    @Binding var selection: Value
    let choices: [CapsuleChoice<Value>]

    private var title: String {
        for case .option(let title, let value) in choices where value == selection { return title }
        return ""
    }

    var body: some View {
        Menu {
            ForEach(choices) { choice in
                switch choice {
                case .option(let title, let value):
                    Button {
                        selection = value
                    } label: {
                        if value == selection { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                case .divider:
                    Divider()
                }
            }
        } label: {
            CapsuleLabel(title: title)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text(label))
        .accessibilityValue(title)
    }
}
