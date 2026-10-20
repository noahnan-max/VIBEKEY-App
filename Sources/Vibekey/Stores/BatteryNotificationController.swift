import AppKit
import Combine
import UserNotifications
import VibekeyCore

enum BatteryNotificationPermission: Equatable {
    case checking, notDetermined, denied, authorized, provisional, unknown
    var allowsDelivery: Bool { self == .authorized || self == .provisional }
}

/// Injectable so command-line checks never obtain the process's native center.
@MainActor protocol BatteryNotificationCenterAccess: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

@MainActor private final class NativeBatteryNotificationCenter: BatteryNotificationCenterAccess {
    private let center: UNUserNotificationCenter
    init(_ center: UNUserNotificationCenter) { self.center = center }
    func authorizationStatus() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
}

@MainActor final class BatteryNotificationController: ObservableObject {
    @Published private(set) var permission: BatteryNotificationPermission = .checking
    @Published private(set) var isRequesting = false
    @Published private(set) var lastDeliveryMessage: String?
    private let client: BatteryNotificationCenterAccess
    private let clock: () -> Date
    private let isCurrent: (BatteryAlert) -> Bool
    private var pending: [BatteryAlert] = []
    private var lastSubmitted: BatteryAlert?

    /// The real App explicitly passes `.current()` here; probes pass a fake
    /// client instead. Construction does not request permission or post.
    convenience init(center: UNUserNotificationCenter, clock: @escaping () -> Date = Date.init,
                     isCurrent: @escaping (BatteryAlert) -> Bool) {
        self.init(client: NativeBatteryNotificationCenter(center), clock: clock, isCurrent: isCurrent)
    }
    init(client: BatteryNotificationCenterAccess, clock: @escaping () -> Date = Date.init,
         isCurrent: @escaping (BatteryAlert) -> Bool) {
        self.client = client; self.clock = clock; self.isCurrent = isCurrent
    }

    var permissionStateText: String {
        switch permission {
        case .checking: return "正在读取系统通知权限"
        case .notDetermined: return "系统通知尚未开启"
        case .denied: return "系统通知未允许"
        case .authorized: return "系统通知已允许"
        case .provisional: return "系统允许安静通知"
        case .unknown: return "系统通知权限未确认"
        }
    }
    var permissionDetail: String {
        switch permission {
        case .notDetermined: return "可主动开启系统通知；未开启时，低电量仍会在 App 中提示。"
        case .denied: return "低电量仍会在 App 中提示。可前往系统设置，为 VIBEKEY 允许通知。"
        case .authorized, .provisional: return "提醒的横幅和声音遵循系统通知设置。"
        case .checking, .unknown: return "低电量仍会在 App 中提示；权限确认前不发送系统通知。"
        }
    }

    /// Parent calls this at App start and when returning from System Settings.
    func refreshPermission() async {
        switch await client.authorizationStatus() {
        case .notDetermined: permission = .notDetermined
        case .denied: permission = .denied
        case .authorized: permission = .authorized
        case .provisional: permission = .provisional
        default: permission = .unknown
        }
    }

    /// Invoke only from the explicit user-facing permission button.
    func requestPermission() async {
        guard !isRequesting else { return }
        isRequesting = true; defer { isRequesting = false }
        await refreshPermission()
        guard permission == .notDetermined else { return }
        do {
            _ = try await client.requestAuthorization(options: [.alert, .sound])
            lastDeliveryMessage = nil
        } catch { lastDeliveryMessage = "系统通知授权未完成：\(error.localizedDescription)" }
        await refreshPermission()
    }

    /// Permission is re-read for every event. There is no prompt fallback and
    /// no replay after permission is granted or the device starts charging.
    func deliver(_ alert: BatteryAlert) async {
        guard canUse(alert), lastSubmitted != alert, !pending.contains(alert) else { return }
        pending.append(alert); defer { pending.removeAll { $0 == alert } }
        await refreshPermission()
        guard permission.allowsDelivery else {
            lastDeliveryMessage = "此次低电量仅在 App 中提醒。"; return
        }
        guard canUse(alert) else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.warning.level == .critical ? "VIBEKEY 电量不足" : "VIBEKEY 电量偏低"
        content.body = alert.warning.message
        content.sound = .default
        content.threadIdentifier = "vibekey.battery"
        let request = UNNotificationRequest(identifier: "vibekey.battery.\(alert.warning.level.rawValue)", content: content, trigger: nil)
        do {
            try await client.add(request)
            lastSubmitted = alert
            lastDeliveryMessage = "低电量提醒已交给系统通知中心。"
        } catch { lastDeliveryMessage = "系统通知未提交，低电量仍在 App 中提示：\(error.localizedDescription)" }
    }
    private func canUse(_ alert: BatteryAlert) -> Bool {
        let age = clock().timeIntervalSince(alert.readAt)
        return age >= 0 && age <= BatteryAlertPolicy.maximumReadingAge && isCurrent(alert)
    }

    @discardableResult func openNotificationSettings() -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return false }
        let opened = NSWorkspace.shared.open(url)
        if !opened { lastDeliveryMessage = "无法打开系统通知设置，请在系统设置的“通知”中选择 VIBEKEY。" }
        return opened
    }
}
