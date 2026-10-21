import SwiftUI

struct LoginItemSettingsSection: View {
    @ObservedObject var store: LoginItemStore
    var body: some View {
        VIFLOWSettingsSection("启动") {
            Toggle("登录时启动 VIBEKEY", isOn: Binding(get: { store.enabled }, set: { store.setEnabled($0) }))
                .toggleStyle(.switch).accessibilityIdentifier("vibekey.login.enabled")
            Text("开机登录后只显示菜单栏图标，不弹出主窗口。需要配置时，从菜单栏打开。")
                .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
            if store.needsApproval {
                HStack { Text("请在系统登录项中允许 VIBEKEY。"); Spacer(); Button("打开登录项设置") { store.openSystemSettings() } }
                    .font(VIFLOWTheme.caption)
            }
            if let error = store.errorMessage { Text(error).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.errorInk) }
        }
    }
}

struct AppUpdateSettingsSection: View {
    @ObservedObject var updates: AppUpdateStore
    let version: String
    @State private var showsNotes = false
    var body: some View {
        VIFLOWSettingsSection("软件更新") {
            HStack {
                Text("当前版本 " + version)
                Spacer()
                Button("检查更新…") { updates.checkNow() }.disabled(!updates.canCheck)
                    .accessibilityIdentifier("vibekey.updates.check")
            }
            Toggle("自动检查更新", isOn: Binding(get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
                .toggleStyle(.switch).accessibilityIdentifier("vibekey.updates.automatic")
            Text(updates.status).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("vibekey.updates.status")
            if let date = updates.lastChecked {
                Text("上次检查：" + date.formatted(date: .abbreviated, time: .shortened))
                    .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
            }
            if let available = updates.availableVersion {
                HStack {
                    Label("新版本 " + available, systemImage: "arrow.down.circle")
                        .foregroundColor(VIFLOWTheme.accent).font(VIFLOWTheme.subheading)
                    Spacer()
                    Button(showsNotes ? "收起更新内容" : "查看更新内容") {
                        showsNotes.toggle(); if showsNotes { updates.markUpdateSeen() }
                    }.accessibilityIdentifier("vibekey.updates.notes")
                }
                if showsNotes {
                    Text(updates.availableNotes).font(VIFLOWTheme.body).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("vibekey.updates.release-notes")
                }
                Button("更新并重新启动…") { updates.installAvailableUpdate() }
                    .disabled(!updates.canCheck).accessibilityIdentifier("vibekey.updates.install")
            }
            if updates.canRetryInstallation {
                Button("重试安装已确认的更新") { updates.resumeInstallation() }
            }
            Text("后台检查不弹窗、不抢焦点。只有点击更新并确认安装后，才下载、校验并替换 App。")
                .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
