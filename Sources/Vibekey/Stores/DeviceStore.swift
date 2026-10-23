import AppKit
import Combine
import VibekeyCore

final class DeviceStore: ObservableObject {
    @Published var connected = false
    @Published var status = "正在查找 AU05"
    @Published var snapshot = DeviceSnapshot()
    @Published private(set) var diagnostics = DeviceSessionDiagnostics()
    @Published private(set) var connectionID:UUID?
    @Published var events: [String] = []
    @Published var editing = false
    @Published var error: String?
    @Published var lastEvent = "等待设备按键"
    @Published private(set) var batteryReadError: String?
    @Published private(set) var lastBatteryAlert: BatteryAlert?
    var onTrigger: ((String, Bool) -> Void)?
    var onDisconnect: (() -> Void)?
    var onControlLoss: (() -> Void)?
    var onManualLightingChange:(()->Void)?
    /// The App may attach its own already-authorized notification delivery.
    /// DeviceStore never requests notification permission.
    var onLowBatteryAlert: ((BatteryAlert) -> Void)?
    private var lightingWriteInFlight=false
    private let session: DeviceSession
    private let clock: () -> Date
    private var batteryTimer: Timer?
    private var batteryPollID: UUID?
    private var batteryConnectionID: UUID?
    private var lastBatteryPollAttemptAt: Date?
    private var batteryAlerts = BatteryAlertPolicy()
    static let batteryPollInterval: TimeInterval = 30
    private var originalHooks: Int?
    private var started = false
    private var onboardReservation: UUID?
    private var pendingBrightness: Int?
    private var pendingBrightnessConnection: UUID?
    private var brightnessTask: Task<Void, Never>?
    private var brightnessFailed = false
    var hasPendingBrightness: Bool { pendingBrightness != nil || brightnessTask != nil }
    var canBeginConfiguration: Bool { isReady && !editing && !lightingWriteInFlight }
    var hasDeviceLease: Bool { originalHooks != nil }
    var isReady:Bool {connected && diagnostics.isDeviceReady}
    var connectionLabel:String {
        if !connected {return "等待 AU05"}
        if diagnostics.authenticationTimedOut {return "接收器未响应"}
        if !diagnostics.authenticated {return "正在连接接收器"}
        if isReady {return "AU05 已就绪"}
        if diagnostics.remoteActive == false {return "等待 AU05 唤醒"}
        if diagnostics.remoteActiveRaw != nil && diagnostics.remoteActive == nil {return "AU05 状态未确认"}
        return diagnostics.readTimeouts > 0 ? "AU05 未响应" : "正在读取 AU05"
    }
    var connectionDetail:String {
        if diagnostics.remoteActive == false && !isReady {return "接收器已连接。请检查 AU05 电源，轻按设备唤醒后重试。"}
        if connected && diagnostics.authenticated && !isReady && diagnostics.readTimeouts > 0 {return "接收器已连接，但 AU05 尚未回应。请检查设备电源和连接后刷新。"}
        return status
    }

    init(session:DeviceSession = DeviceSession(), clock: @escaping () -> Date = Date.init) {
        self.session = session; self.clock = clock
    }
    deinit { batteryTimer?.invalidate() }

    func batteryIsFresh(at now: Date) -> Bool {
        started && isReady && batteryConnectionID == connectionID && batteryReadError == nil &&
            snapshot.batteryReading?.isFresh(at: now, maximumAge: BatteryAlertPolicy.maximumReadingAge) == true
    }
    func batteryWarning(at now: Date) -> BatteryWarning? {
        BatteryAlertPolicy.warning(for: snapshot.batteryReading, at: now, isCurrent: batteryIsFresh(at: now))
    }

    func start() {
        guard !started else { return }; started = true
        session.onConnection = { [weak self] connected, message in
            guard let self = self else { return }
            self.connected = connected; self.status = message
            self.connectionID = connected ? UUID() : nil
            self.batteryConnectionID = nil; self.batteryPollID = nil
            self.lastBatteryPollAttemptAt = nil; self.batteryReadError = nil
            self.log(message)
            if connected { self.snapshot = DeviceSnapshot(); self.session.refresh() }
            else { if self.hasPendingBrightness { self.brightnessFailed = true }; self.pendingBrightness = nil; self.pendingBrightnessConnection = nil; self.onboardReservation = nil; self.editing = false; self.onControlLoss?();self.onDisconnect?() }
        }
        session.onReply = { [weak self] reply in
            guard let self = self else { return }
            var snapshot = self.snapshot
            let now = self.clock()
            if snapshot.apply(reply, at: now) {
                self.snapshot = snapshot
                if reply.isRead, reply.matches(.battery) {
                    self.batteryConnectionID = self.connectionID; self.batteryReadError = nil
                    if let alert = self.batteryAlerts.evaluate(snapshot.batteryReading, at: now, isCurrent: self.batteryIsFresh(at: now)) {
                        self.lastBatteryAlert = alert; self.log(alert.warning.message); self.onLowBatteryAlert?(alert)
                    }
                }
            }
        }
        session.onLog = { [weak self] in self?.log($0) }
        session.onDiagnostics = { [weak self] value in
            guard let self else {return}
            let lost = value.lostDevice(since:self.diagnostics)
            self.diagnostics = value
            if lost {
                self.connectionID=UUID();self.batteryConnectionID=nil;self.batteryPollID=nil
                self.onControlLoss?();self.onDisconnect?()
            }
        }
        session.onEvent = { [weak self] in self?.handleEvent($0) }
        session.start()
        // Check the deadline once a second; HID reads remain at least 30s apart.
        // A repeating 30s timer compared to the previous reply's timestamp can
        // miss every other tick because a reply arrives just after its tick.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshBatteryIfDue()
        }
        batteryTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    /// A due tick is dropped while busy; it never accumulates deferred polls.
    /// The queue guard repeats these checks immediately before USB dispatch.
    func refreshBatteryIfDue() {
        guard started, isReady, !editing, !lightingWriteInFlight, !hasPendingBrightness,
              batteryPollID == nil, let connection = connectionID else { return }
        let now = clock()
        guard now.timeIntervalSince1970.isFinite else {return}
        // A reading made before a wall-clock rollback is not a future retry
        // deadline. Keep the new attempt as the rate limit if recovery fails.
        let last = [lastBatteryPollAttemptAt, snapshot.lastBatteryReadAt].compactMap { $0 }.filter { $0 <= now }.max()
        if let last {
            let elapsed = now.timeIntervalSince(last)
            if elapsed >= 0 && elapsed < Self.batteryPollInterval { return }
        }
        let request = UUID(); batteryPollID = request; lastBatteryPollAttemptAt = now
        session.readIfAllowed(.battery, shouldSend: { [weak self] in
            guard let self else { return false }
            return self.started && self.batteryPollID == request && self.connectionID == connection &&
                self.isReady && !self.editing && !self.lightingWriteInFlight && !self.hasPendingBrightness
        }) { [weak self] result in
            guard let self, self.batteryPollID == request else { return }
            self.batteryPollID = nil
            guard self.connectionID == connection, self.started else { return }
            if case .failure(let error) = result {
                if case SessionError.cancelled = error { return }
                self.batteryReadError = "电量读取未确认：\(error.localizedDescription)"
            }
        }
    }
    private func stopBatteryRefresh() {
        batteryTimer?.invalidate(); batteryTimer = nil; batteryPollID = nil
        batteryConnectionID = nil
    }
    func refresh() { error = nil;session.refresh() }
    func log(_ message: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        events.insert("\(time)  \(message)", at: 0)
        if events.count > 120 { events.removeLast(events.count - 120) }
    }
    private func handleEvent(_ decoded: Data) {
        let bytes = [UInt8](decoded)
        guard bytes.count >= 5, bytes[0] & 0x1f == 0x0b, bytes[1] == 0x10 else { return }
        let physical = bytes[4], status = bytes[3]
        lastEvent = "按键 \(physical) · 状态 \(status)"
        log("\(lastEvent)（逻辑索引 \(bytes[2])）")
        // Exact positions and press/release semantics are supplied by the
        // recovered descriptor; unknown events must never trigger actions.
        if let trigger = HardwareTrigger.resolve(position: physical, status: status) {
            onTrigger?(trigger.id, trigger.pressed)
        }
    }
    func apply(_ command: DeviceCommand, frame: Data, verify: @escaping (DeviceSnapshot) -> Bool) {
        guard connected, !editing else { return }
        editing = true; error = nil
        session.write(command, frame: frame) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e): self.editing = false; self.error = e.localizedDescription
            case .success:
                self.session.read(command) { [weak self] read in
                    guard let self = self else { return }; self.editing = false
                    switch read {
                    case .failure(let e): self.error = e.localizedDescription
                    case .success:
                        if verify(self.snapshot) { self.log("\(command.name)已写入并读回确认") }
                        else { self.error = ControlError.mismatch.localizedDescription }
                    }
                }
            }
        }
    }
    func setNoise(_ level: Int) {
        guard let low = snapshot.noiseLow, let high = snapshot.noiseHigh else { return }
        do { apply(.noiseReduction, frame: try DeviceControls.noiseReduction(level: level, low: low, high: high)) { $0.noiseReduction == level } }
        catch { self.error = error.localizedDescription }
    }
    func setSleep(_ seconds: Int) {
        do { apply(.sleep, frame: try DeviceControls.sleep(seconds: seconds)) { $0.sleepSeconds == seconds } }
        catch { self.error = error.localizedDescription }
    }
    func setHaptics(_ enabled: Bool) {
        guard let value = snapshot.motor, [0, 255].contains(value) else { return }
        let wanted = enabled ? 255 : 0
        apply(.motor, frame: DeviceControls.haptics(enabled: enabled)) { $0.motor == wanted }
    }
    func setLightMode(_ value: Int) {
        onManualLightingChange?()
        do { apply(.lights, frame: try DeviceControls.lightMode(value)) { $0.lightMode == value } }
        catch { self.error = error.localizedDescription }
    }
    func setBrightness(_ value: Int) {
        onManualLightingChange?()
        do { apply(.lights, frame: try DeviceControls.lightBrightness(value)) { $0.lightBrightness == value } }
        catch { self.error = error.localizedDescription }
    }
    @MainActor func stageBrightness(_ value: Int) {
        guard (0...20).contains(value), let connection = connectionID, isReady else { error = ControlError.unavailable.localizedDescription; return }
        pendingBrightness = value; pendingBrightnessConnection = connection; brightnessFailed = false; error = nil
    }
    /// Starts only a user-staged value from the current connection. An old
    /// view's delayed callback after reconnect can never register a new write.
    @MainActor func requestBrightness(_ value: Int) {
        guard pendingBrightness == value, let connection = pendingBrightnessConnection, connection == connectionID, isReady, !brightnessFailed else { return }
        if brightnessTask == nil, snapshot.lightBrightness == value { pendingBrightness = nil; pendingBrightnessConnection = nil; error = nil; return }
        guard brightnessTask == nil else { return }
        brightnessTask = Task { [weak self] in
            guard let self else { return }; defer { brightnessTask = nil }
            while pendingBrightness != nil {
                guard connectionID == connection, isReady else { brightnessFailed = true; pendingBrightness = nil; pendingBrightnessConnection = nil; error = "设备连接已改变，亮度尚未确认。"; return }
                if editing || lightingWriteInFlight { try? await Task.sleep(nanoseconds: 80_000_000); continue }
                guard let target = pendingBrightness else { return }; pendingBrightness = nil
                setBrightness(target)
                while editing, connectionID == connection { try? await Task.sleep(nanoseconds: 80_000_000) }
                if error != nil || snapshot.lightBrightness != target { brightnessFailed = true; pendingBrightness = nil; return }
            }
        }
    }
    @MainActor func flushAutomaticChanges() async -> Bool {
        if brightnessTask == nil, let target = pendingBrightness, !brightnessFailed { requestBrightness(target) }
        await brightnessTask?.value
        return !hasPendingBrightness && !editing && !brightnessFailed
    }
    func setTakeover(_ enabled: Bool) {
        guard let current = snapshot.hooks else { error = ControlError.unavailable.localizedDescription; return }
        if enabled { originalHooks = current }
        let wanted = enabled ? 1 : (originalHooks ?? 0)
        apply(.hooks, frame: DeviceControls.hooks(enabled: wanted != 0)) { $0.hooks == wanted }
    }
    @MainActor func readLighting(connection id:UUID) async throws -> SmartLightingSnapshot {
        guard connectionID == id,isReady else {throw SmartLightingFailure.connectionChanged}
        let reply:DeviceReply = try await withCheckedThrowingContinuation {continuation in
            session.read(.lights) {continuation.resume(with:$0)}
        }
        guard connectionID == id,isReady else {throw SmartLightingFailure.connectionChanged}
        return try SmartLightingSnapshot(connectionID:id,payload:Array(reply.payload))
    }
    @MainActor func applyLighting(_ request:SmartLightingWriteRequest,permit:SmartLightingPermit,onboardPermit:UUID? = nil) async throws -> SmartLightingSnapshot {
        guard !lightingWriteInFlight, onboardReservation == onboardPermit else {throw SmartLightingApplyError(.unavailable)}
        lightingWriteInFlight=true;defer {lightingWriteInFlight=false}
        var observed:SmartLightingSnapshot?
        do {
            guard permit.isValid else {throw SmartLightingFailure.cancelled}
            let initial=try await readLighting(connection:request.connectionID);observed=initial
            guard initial == request.expected else {throw SmartLightingFailure.ownershipChanged}
            for step in request.steps {
                guard permit.isValid else {throw SmartLightingFailure.cancelled}
                guard connectionID == request.connectionID,isReady else {throw SmartLightingFailure.connectionChanged}
                guard observed == step.expected else {throw SmartLightingFailure.ownershipChanged}
                let _:DeviceReply = try await withCheckedThrowingContinuation {continuation in
                    session.write(.lights,frame:step.frame,shouldSend:{[weak self] in
                        permit.isValid && self?.connectionID == request.connectionID && self?.isReady == true && self?.onboardReservation == onboardPermit
                    }) {continuation.resume(with:$0)}
                }
                // Even a revoked operation reads back an already-issued frame.
                // An ACK alone must never become the restoration baseline.
                let after=try await readLighting(connection:request.connectionID);observed=after
                guard after == step.target else {throw SmartLightingFailure.readbackMismatch}
            }
            guard let observed,observed == request.target else {throw SmartLightingFailure.readbackMismatch}
            return observed
        } catch {
            let reason:SmartLightingFailure
            if let value=error as? SmartLightingFailure {reason=value}
            else if !permit.isValid {reason = .cancelled}
            else if connectionID != request.connectionID {reason = .connectionChanged}
            else {reason = .transport}
            throw SmartLightingApplyError(reason,lastReadback:observed)
        }
    }
    @MainActor func readSmartFirmware(connection: UUID, permit: UUID) async throws -> String {
        guard onboardAvailable(connection: connection, permit: permit) else { throw AU05ShortcutError.disconnected }
        let reply: DeviceReply = try await withCheckedThrowingContinuation { continuation in
            session.read(.version) { continuation.resume(with: $0) }
        }
        guard onboardAvailable(connection: connection, permit: permit) else { throw AU05ShortcutError.disconnected }
        var value = DeviceSnapshot(); guard value.apply(reply), let firmware = value.firmware else { throw AU05ShortcutError.invalidReply }; return firmware
    }
    func beginOnboardOperation(connection: UUID) throws -> UUID {
        guard connectionID == connection, isReady else { throw AU05ShortcutError.disconnected }
        guard !editing, !lightingWriteInFlight else { throw AU05ShortcutError.busy }
        let permit = UUID(); onboardReservation = permit; editing = true; return permit
    }
    func endOnboardOperation(_ permit: UUID) {
        guard onboardReservation == permit else { return }; onboardReservation = nil; editing = false
    }
    func onboardAvailable(connection: UUID, permit: UUID) -> Bool {
        connectionID == connection && isReady && onboardReservation == permit
    }
    @MainActor func readOnboardShortcut(index: UInt8, connection: UUID, permit: UUID) async throws -> AU05OnboardShortcut {
        guard index < 6, onboardAvailable(connection: connection, permit: permit) else { throw AU05ShortcutError.disconnected }
        let reply: DeviceReply = try await withCheckedThrowingContinuation { continuation in
            session.readMatching(AU05OnboardShortcut.command, payload: [index], matching: { $0.payload.count >= 12 && $0.payload[0] == index && $0.payload[11] == 0 }, completion: { continuation.resume(with: $0) })
        }
        guard onboardAvailable(connection: connection, permit: permit) else { throw AU05ShortcutError.disconnected }
        return try AU05OnboardShortcut(reply: reply, index: index)
    }
    @MainActor func writeOnboardShortcut(_ value: AU05OnboardShortcut, connection: UUID, permit: UUID) async throws {
        guard onboardAvailable(connection: connection, permit: permit) else { throw AU05ShortcutError.disconnected }
        let frame = try value.writeFrame()
        let _: DeviceReply = try await withCheckedThrowingContinuation { continuation in
            session.write(AU05OnboardShortcut.command, frame: frame, shouldSend: { [weak self] in self?.onboardAvailable(connection: connection, permit: permit) == true }) { continuation.resume(with: $0) }
        }
        guard onboardAvailable(connection: connection, permit: permit) else { throw AU05ShortcutError.disconnected }
    }
    func stopForExit() { stopBatteryRefresh(); started = false; session.stop() }
    func restoreForExit() async throws {
        stopBatteryRefresh()
        if let original = originalHooks {
            let _: DeviceReply = try await withCheckedThrowingContinuation { continuation in
                session.write(.hooks, frame: DeviceControls.hooks(enabled: original != 0)) { continuation.resume(with: $0) }
            }
            let reply: DeviceReply = try await withCheckedThrowingContinuation { continuation in
                session.read(.hooks) { continuation.resume(with: $0) }
            }
            guard reply.payload.first == UInt8(original) else { throw ControlError.mismatch }
            originalHooks = nil
        }
        started = false; session.stop()
    }
}
