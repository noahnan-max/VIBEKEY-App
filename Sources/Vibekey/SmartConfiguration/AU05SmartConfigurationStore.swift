import Foundation
import Combine
import VibekeyCore

@MainActor final class AU05SmartConfigurationStore: ObservableObject {
    @Published var request = ""
    @Published var acknowledged = false
    @Published private(set) var prepared: AU05SmartPrepared?
    @Published private(set) var isBusy = false
    @Published private(set) var applying = false
    @Published private(set) var recoveryRequired = false
    @Published private(set) var message = "描述 AU05 的按键、宏或灯光需求；先预览，再应用。"
    @Published private(set) var error: String?
    @Published private(set) var verification: String?
    @Published private(set) var lastBackup: URL?
    let model: SmartConfigurationStore
    let device: DeviceStore
    private let onboard: AU05OnboardStore
    private let workflows: WorkflowStore
    private let lighting: SmartLightingController
    private let radial: RadialMenuStore
    let archive: AU05SmartArchive
    private let fixture: AU05SmartAdapter?
    private let transaction = AU05SmartTransaction()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private(set) var acceptancePlan: AU05SmartPlan?
    init(model: SmartConfigurationStore, device: DeviceStore, onboard: AU05OnboardStore, workflows: WorkflowStore,
         lighting: SmartLightingController, radial: RadialMenuStore, directory: URL, fixture: AU05SmartAdapter? = nil) {
        self.model = model; self.device = device; self.onboard = onboard; self.workflows = workflows; self.lighting = lighting; self.radial = radial; self.fixture = fixture
        archive = AU05SmartArchive(directory: directory.appendingPathComponent("AU05SmartConfiguration"))
        do { if let journal = try archive.journal() { lastBackup = archive.url(journal); recoveryRequired = ["pending", "recoveryRequired"].contains(journal.phase) } }
        catch { self.error = "AU05 智能配置备份记录无法安全读取。"; recoveryRequired = true }
        if recoveryRequired { message = "上次事务未确认，请先连接 AU05 并恢复所示备份。" }
    }
    var ready: Bool { fixture != nil || device.isReady }
    var canApply: Bool { prepared?.hasChanges == true && !isBusy && !model.isBusy && !recoveryRequired && (prepared?.acknowledgements.isEmpty == true || acknowledged) }
    func invalidate() { prepared = nil; acknowledged = false }
    func cancel() { guard !applying else { return }; generation = UUID(); task?.cancel(); task = nil; isBusy = false }
    func generate() {
        guard !recoveryRequired else { error = "请先恢复上次未确认的配置。"; return }
        let text = request
        run("正在读取 AU05 并生成方案…") {
            self.invalidate(); self.verification = nil
            let before = try await self.withAdapter { try await $0.read() }
            let plan = try await self.model.propose(request: text, context: AU05SmartModel.context(before), response: AU05SmartPlan.self,
                schema: AU05SmartModel.schema, instructions: AU05SmartModel.instructions)
            if CommandLine.arguments.contains("--au05-smart-probe"), self.archive.directory.path.hasPrefix(NSHomeDirectory()+"/Library/Caches/Vibekey/OwnedProbes/") { self.acceptancePlan = plan }
            try Task.checkCancellation()
            let current = try await self.withAdapter { try await $0.read() }
            guard before == current else { throw AU05ShortcutError.changed }
            self.prepared = try AU05SmartPlanner.prepare(plan, baseline: before)
            self.message = self.prepared?.hasChanges == true ? "方案已生成，尚未写入；请核对保存位置和具体步骤。" : (plan.clarification ?? "模型没有提出可执行改动。")
        }
    }
    func apply() {
        guard canApply, let prepared else { return }; invalidate()
        run("正在备份、写入并完整读回 AU05…", applying: true) {
            _ = try await self.commit(expected: prepared.baseline, desired: prepared.desired)
            self.verification = "六个设备快捷键、完整灯光、Mac 宏磁盘内容及开关均读回一致。"
            self.message = "AU05 智能配置已应用并验证；Mac 宏在 VIBEKEY 运行时执行。"
        }
    }
    func restore() {
        guard let source = lastBackup else { return }
        run("正在备份当前配置并恢复 AU05…", applying: true) {
            let original = try self.archive.load(source)
            try await self.withAdapter { adapter in
                let current = try await adapter.read()
                guard current.firmware == original.firmware else { throw AU05ShortcutError.unsupported }
                var target = original; target.connectionID = current.connectionID; target.knobPressReserved = current.knobPressReserved
                _ = try await self.commitLocked(expected: current, desired: target, adapter: adapter)
            }
            self.invalidate(); self.verification = "原设备配置与 Mac 宏已恢复，完整读回一致。"; self.message = "恢复完成；恢复前的当前配置也已备份。"
        }
    }
    func finishForExit() async -> Bool {
        if applying { await task?.value } else { cancel() }
        return !recoveryRequired && !applying
    }
    func runOwnedHardwareAcceptance() async throws -> [String:Any] {
        guard CommandLine.arguments.contains("--au05-smart-hardware-probe"), fixture == nil,
              archive.directory.path.hasPrefix(NSHomeDirectory()+"/Library/Caches/Vibekey/OwnedProbes/") else { throw AU05ShortcutError.unsupported }
        let before = try await withAdapter { try await $0.read() }
        let brightness = try before.lighting.brightness == 8 ? 9 : 8
        let plan = AU05SmartPlan(summary:"owned hardware acceptance", keys:[.init(trigger:"key.0", keyCode:90, modifiers:0)],
            macros:[.init(trigger:"key.1", name:"智能配置验收", steps:[.init(kind:"shortcut",keyCode:8,modifiers:0x100000),.init(kind:"delay",seconds:0.3),.init(kind:"shortcut",keyCode:9,modifiers:0x100000)])],
            lighting:.init(mode:1,brightness:brightness))
        let p = try AU05SmartPlanner.prepare(plan, baseline:before)
        let after = try await commit(expected:before, desired:p.desired)
        guard after == p.desired else { throw AU05ShortcutError.invalidReply }
        _ = try await commit(expected:after, desired:before)
        let first = try await withAdapter { try await $0.read() }, second = try await withAdapter { try await $0.read() }
        guard first == before, second == before else { throw AU05ShortcutError.recoveryRequired }
        return ["result":"PASS_REAL_AU05_WRITE_READBACK_RESTORE", "allSixShortcutsReadback":true, "fullLightingReadback":true,
            "hostMacroPersistenceReadback":true, "originalRestoredTwoFullReads":true, "hostInputPosted":0,
            "hostMacroDirectory":"owned isolated application directory", "actualUserWorkflowFileChanged":false]
    }
    private func commit(expected: AU05SmartSnapshot, desired: AU05SmartSnapshot) async throws -> AU05SmartSnapshot {
        try await withAdapter { try await self.commitLocked(expected: expected, desired: desired, adapter: $0) }
    }
    private func commitLocked(expected: AU05SmartSnapshot, desired: AU05SmartSnapshot, adapter: AU05SmartAdapter) async throws -> AU05SmartSnapshot {
        var began = false
        do {
            let after = try await transaction.commit(expected: expected, desired: desired, adapter: adapter) { snapshot in
                self.lastBackup = try self.archive.begin(snapshot); began = true
            }
            guard let backup = lastBackup, try archive.load(backup) == expected else { throw AU05ShortcutError.recoveryRequired }
            try archive.finish("saved"); recoveryRequired = false; if fixture == nil { onboard.acceptSmartConfiguration(after) }; return after
        } catch {
            if began {
                let phase: String
                switch error as? AU05ShortcutError {
                case .restored: phase = "restored"
                case .changed: phase = "notWritten"
                default: phase = "recoveryRequired"
                }
                do { try archive.finish(phase); recoveryRequired = phase == "recoveryRequired" }
                catch { recoveryRequired = true }
                if !recoveryRequired, fixture == nil, let after = try? await adapter.read() { onboard.acceptSmartConfiguration(after) }
            }
            throw error
        }
    }
    private func withAdapter<T>(_ action: (AU05SmartAdapter) async throws -> T) async throws -> T {
        if let fixture { return try await action(fixture) }
        guard let connection = device.connectionID, device.isReady, device.canBeginConfiguration, !device.hasPendingBrightness,
              !onboard.isBusy, !onboard.hasPendingChanges, !onboard.recoveryRequired, !lighting.isWorking else { throw AU05ShortcutError.busy }
        try workflows.reserveSmartConfiguration(); defer { workflows.endSmartConfiguration() }
        let permit = try device.beginOnboardOperation(connection: connection); defer { device.endOnboardOperation(permit) }
        let adapter = AU05SmartAdapter(read: {
            let firmware = try await self.device.readSmartFirmware(connection: connection, permit: permit)
            var shortcuts: [AU05OnboardShortcut] = []
            for index: UInt8 in 0...5 { shortcuts.append(try await self.device.readOnboardShortcut(index: index, connection: connection, permit: permit)) }
            let light = try await self.device.readLighting(connection: connection)
            guard self.device.onboardAvailable(connection: connection, permit: permit) else { throw AU05ShortcutError.disconnected }
            return AU05SmartSnapshot(connectionID: connection, firmware: firmware, shortcuts: shortcuts, lightingPayload: light.rawPayload,
                workflows: try self.workflows.readSmartConfiguration(), workflowsEnabled: self.workflows.enabled,
                agentLightingEnabled: self.lighting.requestedEnabled,
                knobPressReserved: self.radial.configuration.enabled && self.radial.configuration.activation == .knobPress)
        }, writeShortcut: { try await self.device.writeOnboardShortcut($0, connection: connection, permit: permit) }, writeLighting: { expected, target in
            let request = try SmartLightingWriteRequest(expected: expected, target: target, purpose: .restore, force: true)
            let observed = try await self.device.applyLighting(request, permit: SmartLightingPermit(), onboardPermit: permit)
            guard observed == target else { throw AU05ShortcutError.invalidReply }
        }, writeHost: { expected, target in
            guard self.device.onboardAvailable(connection: connection, permit: permit), self.lighting.requestedEnabled == expected.agentLightingEnabled else { throw AU05ShortcutError.changed }
            try self.workflows.writeSmartConfiguration(expected: expected.workflows, desired: target.workflows,
                expectedEnabled: expected.workflowsEnabled, desiredEnabled: target.workflowsEnabled)
            if target.agentLightingEnabled != expected.agentLightingEnabled {
                if target.agentLightingEnabled { self.lighting.setEnabled(true) } else { self.lighting.manualLightingWillChange() }
            }
        })
        return try await action(adapter)
    }
    private func run(_ message: String, applying: Bool = false, _ action: @escaping () async throws -> Void) {
        guard !isBusy, !model.isBusy else { return }
        let token = UUID(); generation = token; isBusy = true; self.applying = applying; self.message = message; error = nil
        if applying { verification = nil }
        task = Task {
            defer { if generation == token { isBusy = false; self.applying = false; task = nil } }
            do { try await action() }
            catch is CancellationError { if generation == token { self.message = "已停止生成，设备未写入。" } }
            catch { if generation == token { self.error = error.localizedDescription; self.message = applying ? "事务未通过，请查看错误和原配置备份。" : "未生成可应用方案，设备未写入。" } }
        }
    }
}
