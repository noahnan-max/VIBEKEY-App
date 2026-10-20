import AppKit
import Combine
import VibekeyCore

@MainActor final class AU05OnboardStore: ObservableObject {
    @Published private(set) var configurations: [UInt8: AU05OnboardShortcut] = [:]
    @Published private(set) var drafts: [UInt8: AU05OnboardShortcut] = [:]
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    @Published private(set) var message = "等待 AU05 就绪后读取快捷键"
    @Published private(set) var recoveryRequired = false
    @Published private(set) var hasPendingChanges = false
    var canApply: () -> Bool = { true }
    var onConfigurationChanged: (() -> Void)?
    private let device: DeviceStore
    private let preferences: UserDefaults?
    private var transaction: AU05ShortcutTransaction?
    private var loadedConnection: UUID?
    private var attemptedConnection: UUID?
    private var subscription: AnyCancellable?
    private var pending: Task<Void, Never>?
    private var loading = false
    private var revision = 0
    private var storageBlocked = false
    init(device: DeviceStore, directory: URL, preferences: UserDefaults? = .standard) {
        self.device = device; self.preferences = preferences
        do {
            transaction = try AU05ShortcutTransaction(archive: AU05ShortcutArchive(directory: directory.appendingPathComponent("OnboardShortcuts")))
            recoveryRequired = transaction?.recovery != nil
        } catch { self.error = "设备配置恢复记录无法读取，请检查私有备份。"; storageBlocked = true; recoveryRequired = true }
    }
    func start() {
        guard subscription == nil else { return }
        subscription = Publishers.Merge(device.$diagnostics.map { _ in () }, device.$connectionID.map { _ in () })
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }
                if loadedConnection != device.connectionID {
                    if !hasPendingChanges { drafts = [:] }
                }
                if device.isReady, attemptedConnection != device.connectionID, !loading, !isBusy, !hasPendingChanges { refresh() }
            }
    }
    func refresh() {
        guard !loading, !isBusy, !hasPendingChanges, let connection = device.connectionID, device.isReady else { return }
        loading = true; isBusy = true; attemptedConnection = connection; message = "正在读取设备快捷键"
        Task {
            defer { loading = false; isBusy = false }
            do {
                let permit = try device.beginOnboardOperation(connection: connection); defer { device.endOnboardOperation(permit) }
                var values: [UInt8: AU05OnboardShortcut] = [:]
                for index: UInt8 in 0...5 { values[index] = try await device.readOnboardShortcut(index: index, connection: connection, permit: permit) }
                configurations = values; drafts = values; loadedConnection = connection
                if !recoveryRequired { error = nil }; message = "已读取设备中的 6 个快捷键"; onConfigurationChanged?()
            } catch { self.error = error.localizedDescription; message = "设备配置尚未读全" }
        }
    }
    func configuration(for triggerID: String) -> AU05OnboardShortcut? {
        guard loadedConnection == device.connectionID, let index = AU05OnboardShortcut.index(for: triggerID) else { return nil }
        return configurations[index]
    }
    func draft(for triggerID: String) -> AU05OnboardShortcut? {
        AU05OnboardShortcut.index(for: triggerID).flatMap { drafts[$0] }
    }
    func edit(_ entries: [AU05ShortcutEntry], triggerID: String) {
        guard !recoveryRequired, !storageBlocked, let index = AU05OnboardShortcut.index(for: triggerID), let value = drafts[index] else { return }
        do {
            let candidate = try value.replacing(entries: entries)
            guard candidate != drafts[index] else { self.error = nil; message = hasPendingChanges ? "正在自动保存到设备…" : "当前设置无变化"; return }
            drafts[index] = candidate; error = nil; revision += 1; hasPendingChanges = true
            message = "正在自动保存到设备…"; schedule()
        } catch { self.error = error.localizedDescription; message = "设置未应用" }
    }
    func record(_ shortcut: RecordedShortcut, triggerID: String) {
        do { edit(try AU05OnboardShortcut.entries(for: shortcut), triggerID: triggerID) }
        catch { self.error = error.localizedDescription; message = "此快捷键未应用到设备" }
    }
    private func schedule() {
        pending?.cancel()
        pending = Task {
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            while !canApply() || isBusy || !device.canBeginConfiguration {
                guard !Task.isCancelled else { return }
                guard device.isReady else { error = "设备已断开，本次修改尚未写入。"; return }
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
            guard !Task.isCancelled else { return }; pending = nil; await applyPending()
        }
    }
    private func applyPending() async {
        guard !isBusy, hasPendingChanges, !recoveryRequired, let transaction, let connection = device.connectionID, connection == loadedConnection else {
            if hasPendingChanges { error = "设备连接已改变，未自动写入；重新连接原设备后重试。" }; return
        }
        let operationRevision = revision
        let changes = drafts.values.filter { configurations[$0.index] != $0 }.sorted { $0.index < $1.index }
        isBusy = true; defer { isBusy = false }
        do {
            let permit = try device.beginOnboardOperation(connection: connection); defer { device.endOnboardOperation(permit) }
            let adapter = adapter(connection: connection, permit: permit)
            for target in changes {
                guard let original = configurations[target.index] else { throw AU05ShortcutError.changed }
                try await transaction.save(original: original, target: target, adapter: adapter)
                configurations[target.index] = target
            }
            hasPendingChanges = drafts != configurations; error = nil; message = hasPendingChanges ? "正在自动保存到设备…" : "已自动保存到 AU05"
            onConfigurationChanged?()
            if revision != operationRevision, hasPendingChanges { schedule() }
        } catch {
            recoveryRequired = transaction.recovery != nil; self.error = error.localizedDescription
            message = recoveryRequired ? "配置恢复需要处理" : "自动保存未完成"
        }
    }
    private func adapter(connection: UUID, permit: UUID) -> AU05ShortcutAdapter {
        AU05ShortcutAdapter(available: { [weak device] in device?.onboardAvailable(connection: connection, permit: permit) == true },
            read: { [device] in try await device.readOnboardShortcut(index: $0, connection: connection, permit: permit) },
            write: { [device] in try await device.writeOnboardShortcut($0, connection: connection, permit: permit) })
    }
    func retry() { guard !isBusy, !recoveryRequired else { return }; schedule() }
    func reloadFromDevice() {
        guard !isBusy, !recoveryRequired else { return }
        pending?.cancel(); pending = nil; hasPendingChanges = false; drafts = [:]; loadedConnection = nil; refresh()
    }
    func recover() {
        guard !isBusy, !storageBlocked, let transaction, let connection = device.connectionID, device.isReady else { return }
        isBusy = true
        Task {
            do {
                let permit = try device.beginOnboardOperation(connection: connection); defer { device.endOnboardOperation(permit) }
                try await transaction.recover(adapter: adapter(connection: connection, permit: permit))
                recoveryRequired = false; hasPendingChanges = false; loadedConnection = nil; configurations = [:]; drafts = [:]; error = nil
                message = "原设备配置已恢复"
            } catch { self.error = error.localizedDescription }
            isBusy = false
            if !recoveryRequired { refresh() }
        }
    }
    func flush() async -> Bool {
        pending?.cancel(); pending = nil
        let deadline = Date().addingTimeInterval(12)
        while isBusy || (hasPendingChanges && device.isReady && !device.canBeginConfiguration), Date() < deadline { try? await Task.sleep(nanoseconds: 80_000_000) }
        if !isBusy, hasPendingChanges { await applyPending() }
        return !isBusy && !hasPendingChanges && !recoveryRequired
    }
    func installLayoutFixture(_ values: [AU05OnboardShortcut], error: String? = nil) {
        guard preferences == nil, CommandLine.arguments.contains("--ui-probe") else { return }
        configurations = Dictionary(uniqueKeysWithValues: values.map { ($0.index, $0) }); drafts = configurations
        message = "布局预览 · 未连接实体设备"; self.error = error
    }
}
