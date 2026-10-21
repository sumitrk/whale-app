import SwiftUI

/// One row of a settings card: an optional icon tile, a title with an optional line under it,
/// and a control on the right. Every other row type is this with a control.
struct SettingsRow<Control: View>: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var icon: SettingsRowIcon?
    @ViewBuilder var control: Control

    init(
        _ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, icon: SettingsRowIcon? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.control = control()
    }

    var body: some View {
        // Top-aligned, so the icon and control stay level with the title when the subtitle wraps. The
        // one-line height keeps a lone title centred on them.
        HStack(alignment: .top, spacing: 12) {
            if let icon {
                SettingsIconTile(symbol: icon.symbol, tint: icon.tint, cornerRadius: 10)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: 28, alignment: .leading)
            Spacer(minLength: 12)
            control
                .frame(minHeight: 28)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
    }
}

/// The icon a row shows.
struct SettingsRowIcon {
    var symbol: String
    var tint: Color

    init(_ symbol: String, _ tint: Color) {
        self.symbol = symbol
        self.tint = tint
    }
}

// MARK: Row types

/// A row with a switch.
struct SettingsToggleRow: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var icon: SettingsRowIcon?
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, icon: SettingsRowIcon? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle, icon: icon) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

/// A row with a pop-up menu.
struct SettingsPickerRow<Value: Hashable>: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var icon: SettingsRowIcon?
    @Binding var selection: Value
    var choices: [CapsuleChoice<Value>]

    init(
        _ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, icon: SettingsRowIcon? = nil,
        selection: Binding<Value>, choices: [CapsuleChoice<Value>]
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        _selection = selection
        self.choices = choices
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle, icon: icon) {
            CapsulePicker(label: title, selection: $selection, choices: choices)
        }
    }
}

/// A row with a slider and its value.
struct SettingsSliderRow<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    var title: LocalizedStringKey
    var icon: SettingsRowIcon?
    @Binding var value: Value
    var range: ClosedRange<Value>
    var step: Value.Stride
    var unit: String
    var digits: Int

    init(
        _ title: LocalizedStringKey, icon: SettingsRowIcon? = nil, value: Binding<Value>, range: ClosedRange<Value>,
        step: Value.Stride, unit: String = "", digits: Int = 0
    ) {
        self.title = title
        self.icon = icon
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.digits = digits
    }

    private var snapped: Binding<Value> {
        Binding(
            get: { value },
            set: { newValue in
                let steps = ((newValue - range.lowerBound) / Value(step)).rounded()
                value = min(max(range.lowerBound + steps * Value(step), range.lowerBound), range.upperBound)
            })
    }

    var body: some View {
        SettingsRow(title, icon: icon) {
            // Snapped here rather than with `step:`, which draws a tick mark per step under the track.
            Slider(value: snapped, in: range)
                .frame(width: 180)
                .accessibilityLabel(title)
            Text(Double(value).formatted(.number.precision(.fractionLength(digits))) + unit)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }
}

/// A row with a button on the right.
struct SettingsButtonRow: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var icon: SettingsRowIcon?
    var action: LocalizedStringKey
    var role: ButtonRole?
    var perform: () -> Void

    init(
        _ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, icon: SettingsRowIcon? = nil,
        action: LocalizedStringKey, role: ButtonRole? = nil, perform: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.action = action
        self.role = role
        self.perform = perform
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle, icon: icon) {
            Button(action, role: role, action: perform)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
        }
    }
}

/// A row that shows a value on the right.
struct SettingsValueRow: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var value: String

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, value: String) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle) {
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
