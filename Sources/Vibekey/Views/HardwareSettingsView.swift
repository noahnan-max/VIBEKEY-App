import AppKit
import SwiftUI

struct HardwareSettingsView:View {
    @ObservedObject var settings:HardwareSettings
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(spacing:12) {
                BrandMark().frame(width:36,height:36)
                VStack(alignment:.leading,spacing:4) {
                    Text("VIBEKEY").font(VIFLOWTheme.title).foregroundColor(VIFLOWTheme.accent)
                    Text("设备配置与宏控制 · "+settings.version).foregroundColor(VIFLOWTheme.secondary)
                }
            }
            VIFLOWSettingsSection("外观") {
                Picker("颜色模式",selection:$settings.appearanceMode) {
                    ForEach(AppAppearance.allCases) {mode in Text(mode.title).tag(mode)}
                }.pickerStyle(.segmented).labelsHidden()
                    .accessibilityLabel("App 外观").accessibilityIdentifier("vibekey.appearance.mode")
                Text("浅色、深色，或自动跟随系统外观。")
                    .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
            }
            Divider()
            HStack {
                Label(settings.accessibilityGranted ? "辅助功能已允许":"辅助功能待允许",systemImage:settings.accessibilityGranted ? "checkmark.circle":"hand.raised")
                Spacer();Button("打开系统设置") {settings.openAccessibilitySettings()}
            }
            Text("快捷键和宏需要辅助功能权限。设备读取、键盘配置与灯光有各自的连接状态。")
                .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
            Divider()
            Text("本地输入法").font(VIFLOWTheme.subheading)
            Text("在按键或轮盘动作中选择“切换本地输入法”，也可以配置该软件已有的快捷键。")
                .foregroundColor(VIFLOWTheme.secondary)
            HStack {
                Button("输入法设置") {if let url=URL(string:"x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {NSWorkspace.shared.open(url)}}
                Spacer();Button("刷新状态") {settings.refresh()}
            }
        }.padding(24).frame(width:540).font(VIFLOWTheme.body)
            .background(VIFLOWTheme.canvas).foregroundColor(VIFLOWTheme.ink)
            .tint(VIFLOWTheme.accent).buttonStyle(VIFLOWSecondaryButtonStyle()).onAppear {settings.refresh()}
    }
}
