import AppKit
import SwiftUI

struct OpenSettingsButton: View {
    var hasUpdate = false
    var body: some View {
        Button {
            SettingsPresentation.show()
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "gearshape").frame(width: 18)
                Text("App 设置…")
                if hasUpdate { Circle().fill(Color(nsColor: .systemRed)).frame(width: 6, height: 6) }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(VIFLOWNavigationButtonStyle())
        .accessibilityIdentifier("vibekey.settings.open").accessibilityValue(hasUpdate ? "有新版本" : "")
    }
}

enum SettingsPresentation {
    @MainActor static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
