import SwiftUI
import VibekeyCore

struct AU05OnboardEditorView: View {
    @ObservedObject var store: AU05OnboardStore
    let triggerID: String
    @State private var choosingShortcut = false
    private var value: AU05OnboardShortcut? { store.draft(for: triggerID) }
    private var kind: String {
        if choosingShortcut { return "shortcut" }
        guard let value else { return "shortcut" }
        if value.entries.isEmpty { return "none" }
        if let direction = value.scrollDirection { return direction > 0 ? "up" : "down" }
        return "shortcut"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let value {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("设备快捷键").font(VIFLOWTheme.subheading)
                        Spacer()
                        Text("自动保存到 AU05").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    }
                    ActionPresetButton(onboardShortcutsOnly: true) { preset in
                        guard let shortcut = preset.onboardShortcut else { return }
                        store.record(shortcut, triggerID: triggerID)
                        choosingShortcut = false
                    }
                    Picker("执行动作", selection: Binding(get: { kind }, set: changeKind)) {
                        Text("快捷键").tag("shortcut")
                        Text("向上滚动").tag("up")
                        Text("向下滚动").tag("down")
                        Text("不执行动作").tag("none")
                    }.accessibilityIdentifier("vibekey.onboard.action")
                    if kind == "shortcut" {
                        Text(choosingShortcut && value.recordedShortcut == nil ? "录制新的快捷键" : value.label).font(VIFLOWTheme.subheading).accessibilityIdentifier("vibekey.onboard.current")
                        ShortcutRecorder(value: value.recordedShortcut ?? RecordedShortcut(keyCode: 0, modifiers: 0), identifier: "vibekey.onboard.recorder", placeholder: value.recordedShortcut == nil ? "点击录制新的快捷键" : nil) {
                            store.record($0, triggerID: triggerID); choosingShortcut = false
                        }.frame(maxWidth: .infinity, minHeight: 34)
                        Text("点击录制后按所需快捷键，松开后自动写入设备。Fn 组合等尚未确认的编码不会下发。")
                            .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if kind == "up" || kind == "down" {
                        Text("使用 AU05 自身的滚动动作，关闭 VIBEKEY 后仍可使用。")
                            .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.viflowPanel(padding: 18).disabled(store.isBusy || store.recoveryRequired || !value.writable)
            } else {
                Text("读取设备配置后即可设置这个位置。").font(VIFLOWTheme.body).foregroundColor(VIFLOWTheme.secondary)
            }
            HStack(spacing: 10) {
                if store.isBusy { ProgressView().controlSize(.small) }
                Text(store.message).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    .accessibilityIdentifier("vibekey.onboard.status")
                Spacer()
                Button("重新读取") { store.reloadFromDevice() }.disabled(store.isBusy || store.recoveryRequired)
                    .accessibilityIdentifier("vibekey.onboard.refresh")
            }
            Text("修改后自动写入 AU05 并核对。关窗后 VIBEKEY 留在菜单栏；从菜单退出后，设备保留已保存的快捷键。")
                .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = store.error {
                VStack(alignment: .leading, spacing: 10) {
                    Label(error, systemImage: "exclamationmark.circle").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.errorInk)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("vibekey.onboard.error")
                    if store.recoveryRequired {
                        Button("恢复上次设备备份") { store.recover() }.disabled(store.isBusy)
                            .accessibilityIdentifier("vibekey.onboard.recover")
                    } else if store.hasPendingChanges {
                        Button("重试自动保存") { store.retry() }.disabled(store.isBusy)
                            .accessibilityIdentifier("vibekey.onboard.retry")
                    }
                }
            }
        }.font(VIFLOWTheme.body).foregroundColor(VIFLOWTheme.ink)
            .onChange(of: triggerID) { _ in choosingShortcut = false }
    }
    private func changeKind(_ kind: String) {
        choosingShortcut = kind == "shortcut"
        switch kind {
        case "up": store.edit([AU05ShortcutEntry(page: 7, usage: 5)], triggerID: triggerID)
        case "down": store.edit([AU05ShortcutEntry(page: 7, usage: 6)], triggerID: triggerID)
        case "none": store.edit([], triggerID: triggerID)
        default: break
        }
    }
}
