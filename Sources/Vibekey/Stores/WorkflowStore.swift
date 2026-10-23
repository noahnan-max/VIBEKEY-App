import AppKit
import Combine
import VibekeyCore

@MainActor final class WorkflowStore: ObservableObject {
    @Published var bindings: [WorkflowBinding] = [] {
        didSet { if autosaveReady, bindings != oldValue { scheduleAutomaticSave() } }
    }
    @Published private(set) var activeBindings:[WorkflowBinding] = []
    private(set) var smartReserved = false
    var hasUnsavedChanges:Bool {bindings != activeBindings}
    @Published var enabled:Bool {didSet {preferences?.set(enabled,forKey:"hardwareCustomActionsEnabled.v1")}}
    private let preferences:UserDefaults?
    @Published var running = false
    @Published var error: String?
    @Published var selectedID: UUID?
    @Published private(set) var automaticSavePending = false
    @Published private(set) var automaticSaveError: String?
    private let runner = HostActions()
    private var task: Task<Void, Never>?
    private var loadFailed = false
    private let url: URL
    private var autosaveReady = false
    private lazy var autosaver = ConfigurationAutosaver { [weak self] in _ = self?.flushAutomaticSave() }
    var onLog: ((String) -> Void)?
    init(directory: URL? = nil, preferences: UserDefaults? = nil) {
        self.preferences = preferences ?? (directory == nil ? .standard : nil)
        enabled = self.preferences?.bool(forKey:"hardwareCustomActionsEnabled.v1") ?? false
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = directory?.appendingPathComponent("workflows.json") ?? support.appendingPathComponent("Vibekey/workflows.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do { bindings = try WorkflowPersistence.load(from: url);activeBindings=bindings }
            catch { self.error = error.localizedDescription; loadFailed = true }
        } else {
            bindings = InitialDeviceConfiguration.defaults
            do {
                try WorkflowPersistence.save(bindings, to: url);activeBindings=try WorkflowPersistence.load(from:url)
                if let preferences = self.preferences, preferences.object(forKey:"hardwareCustomActionsEnabled.v1") == nil {
                    enabled = true
                    preferences.set(true, forKey:"hardwareCustomActionsEnabled.v1")
                }
            }
            catch { self.error = error.localizedDescription; loadFailed = true }
        }
        autosaveReady = true
        if error != nil { automaticSaveError = error }
    }
    var automaticSaveMessage: String {
        if automaticSavePending { return "正在自动保存…" }
        if automaticSaveError != nil { return "自动保存未完成，当前修改尚未生效" }
        return "已自动保存"
    }
    private func scheduleAutomaticSave() {
        automaticSaveError = nil
        automaticSavePending = hasUnsavedChanges
        if automaticSavePending && !smartReserved { autosaver.schedule() } else { autosaver.cancel() }
    }
    @discardableResult func flushAutomaticSave() -> Bool {
        autosaver.cancel(); automaticSavePending = false
        guard hasUnsavedChanges else { return !loadFailed }
        return save()
    }
    func reserveSmartConfiguration() throws {
        guard !smartReserved, !running, !loadFailed, !hasUnsavedChanges, !automaticSavePending else { throw AU05ShortcutError.busy }
        guard try WorkflowPersistence.load(from: url) == activeBindings else { throw AU05ShortcutError.changed }
        autosaver.cancel(); smartReserved = true
    }
    func endSmartConfiguration() { smartReserved = false; if hasUnsavedChanges { scheduleAutomaticSave() } }
    func readSmartConfiguration() throws -> [WorkflowBinding] {
        guard !loadFailed, !hasUnsavedChanges, try WorkflowPersistence.load(from: url) == activeBindings else { throw AU05ShortcutError.changed }
        return activeBindings
    }
    func writeSmartConfiguration(expected: [WorkflowBinding], desired: [WorkflowBinding], expectedEnabled: Bool, desiredEnabled: Bool) throws {
        guard smartReserved, enabled == expectedEnabled, try readSmartConfiguration() == expected else { throw AU05ShortcutError.changed }
        if expected != desired {
            try WorkflowPersistence.save(desired, to: url)
            guard try WorkflowPersistence.load(from: url) == desired else { throw AU05ShortcutError.storage }
            activeBindings = desired; bindings = desired; automaticSavePending = false; automaticSaveError = nil
        }
        enabled = desiredEnabled
    }
    func add() {
        let binding = WorkflowBinding(name: "新工作流", triggerID: "key.1", steps: [WorkflowStep(kind: .delay, seconds: 0.25)])
        bindings.append(binding); selectedID = binding.id
    }
    func selectTrigger(_ id: String) {
        if let binding = bindings.first(where: { $0.triggerID == id && $0.applicationBundleID.isEmpty }) { selectedID = binding.id }
        else {
            let title = HardwareTrigger.available.first(where: { $0.id == id })?.title ?? "设备按键"
            let binding = WorkflowBinding(name: title, triggerID: id, steps: [WorkflowStep(kind: .passthrough, argument: "当前设备映射")])
            bindings.append(binding); selectedID = binding.id
        }
    }
    @discardableResult func save(enableCustomActions: Bool = false) -> Bool {
        if autosaveReady { autosaver.cancel(); automaticSavePending = false }
        guard !loadFailed, !smartReserved else { return false }
        do {
            try WorkflowPersistence.save(bindings,to:url)
            let saved=try WorkflowPersistence.load(from:url)
            guard saved==bindings else {throw WorkflowError.damagedConfiguration}
            activeBindings=saved;error=nil;automaticSaveError=nil
            if enableCustomActions { enabled=true }
            onLog?("工作流已保存并读回确认");return true
        }
        catch { self.error = error.localizedDescription;automaticSaveError = error.localizedDescription;return false }
    }
    func remove(_ id: UUID) { bindings.removeAll { $0.id == id }; selectedID = nil; save() }
    func customBinding(for id:String,applicationBundleID:String)->WorkflowBinding? {
        guard enabled else {return nil}
        let matching=activeBindings.filter{$0.triggerID == id}
        let selected=matching.first{!$0.applicationBundleID.isEmpty && $0.applicationBundleID == applicationBundleID}
            ?? matching.first{$0.applicationBundleID.isEmpty}
        guard let selected,selected.steps.contains(where:{$0.kind != .passthrough}) else {return nil}
        return selected
    }
    func trigger(_ id: String, pressed: Bool) {
        guard enabled, pressed else { return }
        let application = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let matching = activeBindings.filter { $0.triggerID == id }
        if let binding = matching.first(where: { !$0.applicationBundleID.isEmpty && $0.applicationBundleID == application }) ?? matching.first(where: { $0.applicationBundleID.isEmpty }) {
            run(binding)
        }
    }
    func run(_ binding: WorkflowBinding) {
        guard !smartReserved else { return }
        guard !running else { onLog?("已有宏在运行，跳过重复按键"); return }
        if let message = binding.validationError { error = message; return }
        running = true; error = nil
        task = Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.runner.run(binding.steps) { [weak self] message in
                    guard let owner = self else { return }
                    DispatchQueue.main.async { owner.onLog?(message) }
                }
            } catch { await MainActor.run { self.error = error.localizedDescription } }
            await MainActor.run { self.running = false; self.task = nil }
        }
    }
    func cancel() { task?.cancel() }
    func shutdown() async { flushAutomaticSave(); task?.cancel(); await task?.value }
}
