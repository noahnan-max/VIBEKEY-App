import AppKit
import Combine
import ServiceManagement

@MainActor protocol LoginItemManaging {
    var status: SMAppService.Status { get }
    func setEnabled(_ enabled: Bool) throws
}

@MainActor private struct SystemLoginItem: LoginItemManaging {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if status != .enabled { try SMAppService.mainApp.register() }
        } else if status != .notRegistered { try SMAppService.mainApp.unregister() }
    }
}

@MainActor final class LoginItemStore: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var errorMessage: String?
    private let service: LoginItemManaging?

    init(live: Bool = true, service: LoginItemManaging? = nil) {
        self.service = service ?? (live ? SystemLoginItem() : nil)
        refresh()
    }
    func refresh() {
        let status = service?.status ?? .notRegistered
        enabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }
    func setEnabled(_ value: Bool) {
        guard let service else { return }
        errorMessage = nil
        do { try service.setEnabled(value) }
        catch { errorMessage = "登录启动设置未生效：" + error.localizedDescription }
        refresh()
        if errorMessage == nil, enabled != value { errorMessage = "系统尚未确认登录启动设置，请刷新状态后重试。" }
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
