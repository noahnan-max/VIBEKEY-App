import SwiftUI

struct VIFLOWPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VIFLOWTheme.font(13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundColor(isEnabled ? VIFLOWTheme.filledInk : VIFLOWTheme.secondary)
            .background(isEnabled ? (configuration.isPressed ? VIFLOWTheme.filledPressed : hovered ? VIFLOWTheme.filledHover : VIFLOWTheme.filled) : VIFLOWTheme.muted,
                        in: RoundedRectangle(cornerRadius: VIFLOWTheme.controlRadius))
            .contentShape(RoundedRectangle(cornerRadius: VIFLOWTheme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: VIFLOWTheme.controlRadius)
                .stroke(isEnabled && isFocused ? VIFLOWTheme.accent : Color.clear, lineWidth: 2)
                .padding(-3).allowsHitTesting(false))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct VIFLOWSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VIFLOWTheme.font(12.5, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7.5)
            .foregroundColor(isEnabled ? (configuration.role == .destructive ? VIFLOWTheme.errorInk : VIFLOWTheme.ink) : VIFLOWTheme.secondary.opacity(0.65))
            .background(isEnabled && (configuration.isPressed || hovered) ? VIFLOWTheme.muted : VIFLOWTheme.surface,
                        in: RoundedRectangle(cornerRadius: VIFLOWTheme.controlRadius))
            .contentShape(RoundedRectangle(cornerRadius: VIFLOWTheme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: VIFLOWTheme.controlRadius)
                .stroke(isEnabled && hovered ? VIFLOWTheme.controlBorder : VIFLOWTheme.border, lineWidth: 1)
                .allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius: VIFLOWTheme.controlRadius)
                .stroke(isEnabled && isFocused ? VIFLOWTheme.accent : Color.clear, lineWidth: 2)
                .padding(-3).allowsHitTesting(false))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}

/// Flat, full-row navigation, shared by device sections and the Settings entry.
struct VIFLOWNavigationButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VIFLOWTheme.font(13, weight: selected ? .medium : .regular))
            .foregroundColor(!isEnabled ? VIFLOWTheme.secondary : selected ? VIFLOWTheme.filledInk : VIFLOWTheme.ink)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? VIFLOWTheme.filled : isEnabled && (hovered || configuration.isPressed) ? VIFLOWTheme.muted : Color.clear,
                        in: RoundedRectangle(cornerRadius: VIFLOWTheme.controlRadius))
            .contentShape(RoundedRectangle(cornerRadius: VIFLOWTheme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: VIFLOWTheme.controlRadius)
                .stroke(isEnabled && isFocused ? VIFLOWTheme.accent : Color.clear, lineWidth: 2)
                .padding(-2).allowsHitTesting(false))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}

struct VIFLOWCard<Content: View>: View {
    let title: String
    var symbol: String? = nil
    let content: Content

    init(_ title: String, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                if let symbol = symbol {
                    Image(systemName: symbol).foregroundColor(VIFLOWTheme.secondary)
                }
                Text(title).font(VIFLOWTheme.subheading)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .viflowPanel()
    }
}

struct VIFLOWSettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(VIFLOWTheme.subheading)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .viflowPanel(padding: 16)
    }
}

struct VIFLOWSettingsPage<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(VIFLOWTheme.body)
        .foregroundColor(VIFLOWTheme.ink)
        .buttonStyle(VIFLOWSecondaryButtonStyle())
        .tint(VIFLOWTheme.accent)
        .background(VIFLOWTheme.canvas)
    }
}

extension View {
    func viflowPanel(padding: CGFloat = 18) -> some View {
        self.padding(padding)
            .background(VIFLOWTheme.surface,
                        in: RoundedRectangle(cornerRadius: VIFLOWTheme.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: VIFLOWTheme.panelRadius)
                .stroke(VIFLOWTheme.border, lineWidth: 1).allowsHitTesting(false))
    }

    func viflowInput() -> some View {
        self.modifier(VIFLOWInputModifier())
    }
}

private struct VIFLOWInputModifier: ViewModifier {
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func body(content: Content) -> some View {
        content.textFieldStyle(.plain)
            .font(VIFLOWTheme.body)
            .foregroundColor(isEnabled ? VIFLOWTheme.ink : VIFLOWTheme.secondary)
            .focused($isFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(VIFLOWTheme.surface,
                        in: RoundedRectangle(cornerRadius: VIFLOWTheme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: VIFLOWTheme.controlRadius)
                .stroke(isEnabled && isFocused ? VIFLOWTheme.accent : hovered ? VIFLOWTheme.controlBorder : VIFLOWTheme.border, lineWidth: isEnabled && isFocused ? 1.5 : 1)
                .allowsHitTesting(false))
            .onHover { hovered = $0 }
    }
}
