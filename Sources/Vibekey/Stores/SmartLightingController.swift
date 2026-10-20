import Foundation
import Combine
import VibekeyCore

/// No HID ownership. The owner adapts its existing, bounded DeviceSession and
/// must check permit.isValid at the actual transport-send boundary for EACH step.
@MainActor final class SmartLightingController: ObservableObject {
    struct Adapter {
        let read: (UUID) async throws -> SmartLightingSnapshot
        let apply: (SmartLightingWriteRequest, SmartLightingPermit) async throws -> SmartLightingSnapshot
    }
    enum Status: String {
        case disabled, waitingForDevice, waitingForSource, waitingForDeviceAccess, waitingForRateLimit, reading, applying
        case confirmed, restored, relinquished, unavailable, backupUnavailable, restoreUnconfirmed, limitReached
    }
    enum RestoreResult { case restored, nothingBorrowed, relinquished, deferred, unconfirmed }
    struct Confirmation {
        let at: Date
        let state: SmartLightingState?
        let mode: SmartLightingMode
        let brightness: Int
        let restored: Bool
        let wroteSettings: Bool
        let rawPayload: [UInt8]
    }
    @Published private(set) var enabled = false
    @Published private(set) var requestedEnabled = false
    @Published private(set) var state: SmartLightingState = .standby
    @Published private(set) var status: Status = .disabled
    @Published private(set) var brightness = 8
    @Published private(set) var deviceReady = false
    @Published private(set) var lastConfirmedState: SmartLightingState?
    @Published private(set) var latestReadback: SmartLightingSnapshot?
    @Published private(set) var hasBorrowedSettings = false
    @Published private(set) var lastConfirmation: Confirmation?
    var onConfirmation: ((Confirmation) -> Void)?
    /// The real App saves a private complete baseline before any device write.
    var prepareBorrow: ((SmartLightingSnapshot) throws -> Void)?
    private let preferences: UserDefaults?
    private static let enabledKey = "agentLighting.followEnabled.v1"
    private static let brightnessKey = "agentLighting.runningBrightness.v1"
    private let adapter: Adapter
    private let clock: () -> TimeInterval
    private let sleep: (TimeInterval) async throws -> Void
    private var connectionID: UUID?
    private var ownership = UUID()
    private var devicePriority = false
    private var original: SmartLightingSnapshot?
    private var feedbackEvents: [(at: TimeInterval, isApproval: Bool)] = []
    private var lastTransactionAt: TimeInterval?
    private var pending = false
    private var worker: Task<Void, Never>?
    private var wake: Task<Void, Never>?
    private var wakeID = UUID()
    private var restoreTimer: Task<Void, Never>?
    private var stateRevision: UInt64 = 0
    private var permit: SmartLightingPermit?
    private var stopping = false

    init(adapter: Adapter, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(max(0, min(60, seconds)) * 1_000_000_000))
         }, preferences: UserDefaults? = nil) {
        self.adapter = adapter; self.clock = clock; self.sleep = sleep
        self.preferences = preferences
        requestedEnabled = preferences?.bool(forKey: Self.enabledKey) ?? false
        if let value = preferences?.object(forKey: Self.brightnessKey) as? Int, (0...20).contains(value) { brightness = min(12, value) }
    }
    deinit { permit?.revoke(); worker?.cancel(); wake?.cancel(); restoreTimer?.cancel() }

    var isWorking: Bool { worker != nil || wake != nil }
    var statusText: String {
        switch status {
        case .disabled: return "Agent 状态灯未启用；预览不会操作设备。"
        case .waitingForDevice: return "等待设备就绪；不会向新连接补发旧灯光。"
        case .waitingForSource: return "等待真实 Agent 状态；保持设备原灯光。"
        case .waitingForDeviceAccess: return "设备正在配置，灯光设置已暂缓。"
        case .waitingForRateLimit: return "正在合并灯光状态，避免频繁写入。"
        case .reading: return "正在读取原灯光设置。"
        case .applying: return "等待设备写入后的完整读回。"
        case .confirmed: return "设备已读回：" + (lastConfirmedState?.title ?? "当前设置")
        case .restored: return "原灯光已读回恢复。"
        case .relinquished: return "灯光状态已变化，已暂停并保留当前设置。"
        case .unavailable: return "本次灯光操作未确认，未继续发送。"
        case .backupUnavailable: return "原灯光备份未保存，未向设备写入。"
        case .restoreUnconfirmed: return "原灯光恢复未确认；可在同一连接重试停止并恢复。"
        case .limitReached: return "本分钟灯光更新已达上限，保留当前灯光并等待最新状态。"
        }
    }

    func setConnection(id: UUID?, ready: Bool) {
        let usable = ready && id != nil
        guard id != connectionID || usable != deviceReady else { return }
        invalidateOwnership()
        connectionID = id; deviceReady = usable; enabled = usable && requestedEnabled; state = .standby
        status = usable ? (enabled ? .waitingForSource : .disabled) : .waitingForDevice
    }
    func setDevicePriority(_ active: Bool) {
        guard devicePriority != active else { return }
        devicePriority = active
        if active {
            permit?.revoke(); cancelWake()
            if enabled || original != nil { status = .waitingForDeviceAccess; pending = true }
        } else { schedule() }
    }
    func setEnabled(_ value: Bool) {
        setEnabled(value, persistIntent: true)
    }
    private func setEnabled(_ value: Bool, persistIntent: Bool) {
        if value {
            guard !stopping else { return }
            if persistIntent { requestedEnabled = true; preferences?.set(true, forKey: Self.enabledKey) }
            guard !stopping, deviceReady, connectionID != nil, original == nil, worker == nil else {
                if !deviceReady { status = .waitingForDevice }
                return
            }
            enabled = true
            if state == .standby { status = .waitingForSource; return }
            pending = true; schedule()
        } else {
            if persistIntent { requestedEnabled = false; preferences?.set(false, forKey: Self.enabledKey) }
            enabled = false; state = .standby; stateRevision &+= 1
            restoreTimer?.cancel(); restoreTimer = nil; permit?.revoke(); cancelWake()
            pending = original != nil || worker != nil
            if !pending { status = .disabled }
            schedule()
        }
    }
    func setBrightness(_ value: Int) {
        guard (0...20).contains(value), value != brightness else { return }
        brightness = value
        preferences?.set(value, forKey: Self.brightnessKey)
        if enabled { permit?.revoke(); pending = true; schedule() }
    }
    func updateState(_ value: SmartLightingState) {
        guard state != value else { return }
        state = value; stateRevision &+= 1
        restoreTimer?.cancel(); restoreTimer = nil
        guard enabled else { return }
        // A newer authoritative state supersedes unsent frames of the old one.
        // The adapter still returns any complete readback of a partial write.
        permit?.revoke(); cancelWake(); pending = true; schedule()
    }
    /// Call BEFORE a user's manual light write, even if values happen to match.
    func manualLightingWillChange() {
        invalidateOwnership(); enabled = false; state = .standby; status = .relinquished
        requestedEnabled = false; preferences?.set(false, forKey: Self.enabledKey)
    }
    /// Adapter operations must already be bounded by DeviceSession timeouts.
    /// Never forces a restore across a connection/manual-ownership change.
    func stopAndRestore(preserveEnabledIntent: Bool = false) async -> RestoreResult {
        guard !stopping else { return .deferred }
        stopping = true; defer { stopping = false }
        let hadBorrowed = original != nil
        setEnabled(false, persistIntent: !preserveEnabledIntent)
        if devicePriority { return .deferred }
        while let task = worker ?? wake {
            await task.value
            if devicePriority { return .deferred }
        }
        if status == .relinquished { return .relinquished }
        if original != nil { return .unconfirmed }
        return hadBorrowed || status == .restored ? .restored : .nothingBorrowed
    }

    private func cancelWake() { wakeID = UUID(); wake?.cancel(); wake = nil }
    private func invalidateOwnership() {
        ownership = UUID(); permit?.revoke(); permit = nil; cancelWake()
        restoreTimer?.cancel(); restoreTimer = nil; stateRevision &+= 1
        original = nil; latestReadback = nil; hasBorrowedSettings = false
        lastConfirmedState = nil; lastConfirmation = nil; pending = false
    }
    private func schedule() {
        guard pending, worker == nil, wake == nil else { return }
        guard deviceReady, connectionID != nil else { status = .waitingForDevice; return }
        guard !devicePriority else { status = .waitingForDeviceAccess; return }
        let now = clock()
        guard now.isFinite, lastTransactionAt.map({ now >= $0 }) ?? true else {
            enabled = false; pending = false; status = original == nil ? .unavailable : .restoreUnconfirmed; return
        }
        feedbackEvents.removeAll { now - $0.at >= SmartLightingPolicy.feedbackWindow }
        var delay = lastTransactionAt.map { max(0, $0 + SmartLightingPolicy.minimumTransactionInterval - now) } ?? 0
        let restoring = !enabled || state == .standby
        let totalLimited = !restoring && feedbackEvents.count >= SmartLightingPolicy.maximumFeedbackTransactions
        let ordinary = feedbackEvents.filter { !$0.isApproval }
        let ordinaryLimited = !restoring && state != .awaitingApproval && ordinary.count >= SmartLightingPolicy.maximumOrdinaryFeedbackTransactions
        let limited = totalLimited || ordinaryLimited
        if totalLimited, let first = feedbackEvents.first { delay = max(delay, first.at + SmartLightingPolicy.feedbackWindow - now) }
        if ordinaryLimited, let first = ordinary.first { delay = max(delay, first.at + SmartLightingPolicy.feedbackWindow - now) }
        if delay > 0 {
            status = limited ? .limitReached : .waitingForRateLimit
            let token = UUID(); wakeID = token
            wake = Task { [weak self] in
                guard let self else { return }
                do { try await sleep(delay) } catch { return }
                guard !Task.isCancelled, wakeID == token else { return }
                wake = nil; schedule()
            }
            return
        }
        worker = Task { [weak self] in
            guard let self else { return }
            await performOne()
            worker = nil; schedule()
        }
    }
    private func current(_ owner: UUID, _ id: UUID) -> Bool {
        ownership == owner && connectionID == id && deviceReady
    }
    private func armRestoreTimer(afterConfirmed value: SmartLightingState) {
        guard enabled, state == value, let duration = SmartLightingPolicy.automaticRestoreDelay(for: value) else { return }
        restoreTimer?.cancel()
        let revision = stateRevision, owner = ownership
        restoreTimer = Task { [weak self] in
            guard let self else { return }
            do { try await sleep(duration) } catch { return }
            guard !Task.isCancelled, ownership == owner, stateRevision == revision, enabled else { return }
            updateState(.standby)
        }
    }
    private func relinquish() {
        invalidateOwnership(); enabled = false; state = .standby; status = .relinquished
        requestedEnabled = false; preferences?.set(false, forKey: Self.enabledKey)
    }
    private func recordConfirmation(_ value: SmartLightingSnapshot, state: SmartLightingState?, restored: Bool, wroteSettings: Bool) {
        let confirmation = Confirmation(at: Date(), state: state, mode: value.mode, brightness: value.brightness, restored: restored, wroteSettings: wroteSettings, rawPayload:value.rawPayload)
        lastConfirmation = confirmation; onConfirmation?(confirmation)
    }
    private func finishRestore(_ value: SmartLightingSnapshot, wroteSettings: Bool) {
        recordConfirmation(value, state: nil, restored: true, wroteSettings: wroteSettings)
        original = nil; latestReadback = nil; hasBorrowedSettings = false
        lastConfirmedState = nil; status = .restored
    }
    private func performOne() async {
        // Priority may change after schedule() creates this task but before it
        // runs. Keep the pending feedback/restore until device access is released.
        guard !devicePriority else {
            if pending { status = .waitingForDeviceAccess }
            return
        }
        pending = false
        guard let id = connectionID, deviceReady else { return }
        let owner = ownership
        var restoring = !enabled || state == .standby
        if original == nil && restoring { status = enabled ? .restored : .disabled; return }
        let observed: SmartLightingSnapshot
        do {
            status = .reading; observed = try await adapter.read(id)
        } catch {
            guard current(owner, id) else { return }
            enabled = false; status = original == nil ? .unavailable : .restoreUnconfirmed; return
        }
        guard current(owner, id) else { return }
        guard observed.connectionID == id else { relinquish(); return }
        if let last = latestReadback, observed != last { relinquish(); return }
        restoring = !enabled || state == .standby
        if original == nil {
            guard !restoring, enabled, !devicePriority else { return }
            do { try prepareBorrow?(observed) }
            catch { enabled = false; status = .backupUnavailable; return }
            original = observed; latestReadback = observed; hasBorrowedSettings = true
        }
        guard !devicePriority else { pending = true; status = .waitingForDeviceAccess; return }
        guard let saved = original else { return }
        let requestedState = state
        let target: SmartLightingSnapshot
        do {
            if restoring { target = saved }
            else if let intent = try SmartLightingPolicy.intent(for: requestedState, brightness: brightness) { target = try observed.applying(intent) }
            else { return }
        } catch { enabled = false; status = .unavailable; return }
        if observed == target {
            if restoring { finishRestore(observed, wroteSettings: false) }
            else { latestReadback = observed; lastConfirmedState = requestedState; status = .confirmed; recordConfirmation(observed, state: requestedState, restored: false, wroteSettings: false); armRestoreTimer(afterConfirmed: requestedState) }
            return
        }
        let request: SmartLightingWriteRequest
        do { request = try .init(expected: observed, target: target, purpose: restoring ? .restore : .feedback) }
        catch { relinquish(); return }
        let token = SmartLightingPermit(); permit = token
        let now = clock()
        guard now.isFinite, lastTransactionAt.map({ now >= $0 }) ?? true else {
            token.revoke(); permit = nil; enabled = false; pending = false; status = .restoreUnconfirmed; return
        }
        lastTransactionAt = now
        if !restoring { feedbackEvents.append((now, requestedState == .awaitingApproval)) }
        status = .applying
        defer { token.revoke(); if permit === token { permit = nil } }
        do {
            let result = try await adapter.apply(request, token)
            guard current(owner, id) else { return }
            guard adoptReadback(result, request: request) else { relinquish(); return }
            guard result == target else { throw SmartLightingApplyError(.readbackMismatch, lastReadback: result) }
            if restoring { finishRestore(result, wroteSettings: true) }
            else { lastConfirmedState = requestedState; status = .confirmed; recordConfirmation(result, state: requestedState, restored: false, wroteSettings: true); armRestoreTimer(afterConfirmed: requestedState) }
        } catch {
            guard current(owner, id) else { return }
            let failure = error as? SmartLightingApplyError
            if failure?.reason == .ownershipChanged || failure?.reason == .connectionChanged { relinquish(); return }
            if let readback = failure?.lastReadback, !adoptReadback(readback, request: request) { relinquish(); return }
            if devicePriority { pending = true; status = .waitingForDeviceAccess; return }
            if restoring { pending = false; enabled = false; status = .restoreUnconfirmed; return }
            if failure?.reason == .cancelled && enabled { pending = true; return }
            // Keep last hardware readback. A later fresh read must match it
            // before recovery; an unobserved partial write is never guessed.
            enabled = false; state = .standby; pending = true; status = .unavailable
            restoreTimer?.cancel(); restoreTimer = nil
        }
    }
    private func adoptReadback(_ value: SmartLightingSnapshot, request: SmartLightingWriteRequest) -> Bool {
        guard value == request.expected || request.steps.contains(where: { $0.target == value }) else { return false }
        latestReadback = value; return true
    }
}
