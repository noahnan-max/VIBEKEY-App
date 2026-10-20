import SwiftUI
import VibekeyCore

/// Place above the workspace content so a low battery stays visible on every
/// tab. The warning is live state, separate from one-off notification events.
@MainActor struct BatteryAlertBanner: View {
    @ObservedObject var device: DeviceStore
    @ObservedObject var notifications: BatteryNotificationController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            if let warning = device.batteryWarning(at: context.date) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(VIFLOWTheme.errorInk).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(warning.message).font(VIFLOWTheme.subheading)
                            .foregroundColor(VIFLOWTheme.errorInk)
                            .fixedSize(horizontal: false, vertical: true)
                        if !notifications.permission.allowsDelivery {
                            Text(notifications.permissionDetail)
                                .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    if notifications.permission == .denied {
                        Button("通知设置") { notifications.openNotificationSettings() }
                            .accessibilityIdentifier("vibekey.battery.banner.notification-settings")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VIFLOWTheme.errorSoft, in: RoundedRectangle(cornerRadius: VIFLOWTheme.controlRadius))
                .buttonStyle(VIFLOWSecondaryButtonStyle())
                .accessibilityIdentifier("vibekey.battery.global-warning")
            }
        }
    }
}

@MainActor struct BatteryNotificationSettingsView: View {
    @ObservedObject var controller: BatteryNotificationController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("低电量系统通知").font(VIFLOWTheme.subheading)
                Spacer(minLength: 0)
                Text(controller.permissionStateText)
                    .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    .accessibilityIdentifier("vibekey.battery.notification-permission")
            }
            Text(controller.permissionDetail)
                .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if controller.permission == .notDetermined {
                    Button("开启系统通知") { Task { await controller.requestPermission() } }
                        .disabled(controller.isRequesting)
                        .accessibilityIdentifier("vibekey.battery.enable-notifications")
                } else if controller.permission != .checking {
                    Button("打开通知设置") { controller.openNotificationSettings() }
                        .accessibilityIdentifier("vibekey.battery.notification-settings")
                }
                Button("刷新权限") { Task { await controller.refreshPermission() } }
                    .disabled(controller.isRequesting)
                    .accessibilityIdentifier("vibekey.battery.refresh-notification-permission")
                Spacer(minLength: 0)
            }
            if let message = controller.lastDeliveryMessage {
                Text(message).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("vibekey.battery.notification-result")
            }
            Text("设备就绪时自动刷新，关窗后继续提醒；从菜单退出后停止。系统通知不会在授权后补发旧提醒。")
                .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(VIFLOWTheme.ink).buttonStyle(VIFLOWSecondaryButtonStyle())
        .viflowPanel(padding: 16)
        .task { await controller.refreshPermission() }
        .accessibilityIdentifier("vibekey.battery.notification-settings-panel")
    }
}
