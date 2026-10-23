import AppKit
import Combine
import VibekeyCore

@MainActor final class UsageStatisticsStore: ObservableObject {
    @Published private(set) var ledger = UsageStatisticsLedger()
    @Published private(set) var displayLedger = UsageStatisticsLedger()
    @Published private(set) var status = "统计尚未启用"
    @Published private(set) var liveSummary: String?
    @Published private(set) var error: String?
    @Published private(set) var isObserving = false
    let directory: URL
    private struct Live {
        let at: Date
        let uptime: Double
        var ended: Double?
        var characters: Int? = 0
        var failure: InputObservationFailure?
        var seconds: Double { min(600, max(0, (ended ?? ProcessInfo.processInfo.systemUptime) - uptime)) }
    }
    private let writes = DispatchQueue(label: "local.noah.vibekey.usage-storage", qos: .utility)
    private var loadFailed = false
    private var activeID: UUID?
    private var microphoneActive = false
    private var started = false
    private var completedIDs = Set<UUID>()
    private var live: [UUID: Live] = [:]
    private var timer: Timer?
    private var generation = 0
    private let permitsObservation: Bool
    private let observeHardware: Bool
    private let readerFactory: (pid_t) throws -> PassiveInputObserver.Reader
    private lazy var observer = PassiveInputObserver(readerFactory: readerFactory,
        progressed: { [weak self] in self?.progress($0) }, completed: { [weak self] in self?.accept($0) })
    private lazy var microphone = AutomaticMicrophoneMonitor { [weak self] state in
        guard let self, self.started else { return }
        self.microphoneChanged(state, pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
    }

    init(directory: URL, permitsObservation: Bool = true, observeHardware: Bool = true,
         readerFactory: @escaping (pid_t) throws -> PassiveInputObserver.Reader = PassiveInputObserver.capture) {
        self.directory = directory; self.permitsObservation = permitsObservation
        self.observeHardware = observeHardware; self.readerFactory = readerFactory
        do {
            ledger = try UsageStatisticsFile.load(directory: directory)
            if ledger.preferences.collectionEnabled, ledger.startedAt == nil { ledger.startedAt = Date() }
            status = ledger.preferences.collectionEnabled ? "自动统计已开启 · 等待麦克风输入" : "统计已暂停"
        } catch { loadFailed = true; self.error = "统计文件未能读取，已保留原文件。" }
        displayLedger = ledger
    }
    func start() {
        guard permitsObservation, !loadFailed else { return }; started = true
        if observeHardware, collectionEnabled { microphone.start() }
    }
    func stop() { started = false; if observeHardware { microphone.stop() }; preserveReceived(); cancel() }
    var preferences: UsageStatisticsPreferences { ledger.preferences }
    var collectionEnabled: Bool { preferences.collectionEnabled }
    var canChangePreferences: Bool { !loadFailed }
    func setCollectionEnabled(_ enabled: Bool) {
        update {
            $0.enabled = enabled
            if enabled { $0.observationConsentVersion = 1 }
        }
    }
    func update(_ change: (inout UsageStatisticsPreferences) -> Void) {
        guard !loadFailed else { return }
        var next = preferences; change(&next); guard next.isValid else { return }
        preserveReceived(); cancel(); ledger.preferences = next
        if next.collectionEnabled, ledger.startedAt == nil { ledger.startedAt = Date() }
        status = next.collectionEnabled ? "自动统计已开启 · 等待麦克风输入" : "统计已暂停"
        if started, observeHardware { microphone.stop(); if next.collectionEnabled { microphone.start() } }
        refreshDisplay(); save()
    }
    /// Original dispatch has already returned; the only work is queueing a hint.
    func handle(_ id: String, pressed: Bool, pid: pid_t) {
        guard permitsObservation, collectionEnabled, !loadFailed, pressed,
              ["key.0", "key.1", "key.2", "knob.press"].contains(id), !microphoneActive else { return }
        observer.prime(pid: pid)
    }
    func microphoneChanged(_ state: AutomaticMicrophoneMonitor.State, pid: pid_t) {
        guard permitsObservation, collectionEnabled, !loadFailed else { return }
        switch state {
        case .active:
            guard !microphoneActive else { return }; microphoneActive = true; begin(pid: pid)
        case .idle:
            if microphoneActive { microphoneActive = false; end() }
            else if !isObserving { status = "自动统计已开启 · 等待麦克风输入" }
        case .disconnected:
            preserveReceived(); cancel(); status = "自动统计已开启 · 等待 VIBEKEY 麦克风连接"
        case .unreadable:
            preserveReceived(); cancel(); status = "麦克风状态暂不可读 · 等待自动恢复"
        }
    }
    private func begin(pid: pid_t) {
        let id = UUID(), now = ProcessInfo.processInfo.systemUptime, at = Date()
        live[id] = Live(at: at, uptime: now); activeID = id; isObserving = true
        status = "正在收录 · 输入照常进行"
        if timer == nil {
            let value = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshDisplay() }
            }
            timer = value; RunLoop.main.add(value, forMode: .common)
        }
        refreshDisplay(); observer.begin(id: id, at: at, uptime: now, pid: pid)
    }
    private func end() {
        guard let id = activeID else { return }
        activeID = nil; live[id]?.ended = ProcessInfo.processInfo.systemUptime
        status = "麦克风已停止 · 正在接收后续文字"
        refreshDisplay(); observer.end(id: id, uptime: live[id]?.ended ?? ProcessInfo.processInfo.systemUptime)
    }
    func cancel() {
        activeID = nil; live = [:]; microphoneActive = false; isObserving = false; observer.cancel()
        timer?.invalidate(); timer = nil; liveSummary = nil; displayLedger = ledger
        status = collectionEnabled ? "自动统计已开启 · 等待麦克风输入" : "统计已暂停"
    }
    private func progress(_ value: PassiveInputObserver.Progress) {
        guard collectionEnabled, var current = live[value.id], !completedIDs.contains(value.id) else { return }
        current.characters = max(current.characters ?? 0, value.characters ?? 0)
        if value.characters == nil, (current.characters ?? 0) == 0 { current.characters = nil }
        current.failure = value.failure; live[value.id] = current; refreshDisplay()
    }
    private func selection(characters: Int?, failure: InputObservationFailure?, seconds: Double) -> (UsageCountSource, Int?) {
        if let failure, failure != .secure, preferences.estimateWhenUnavailable {
            let estimate = Int((seconds / 60 * Double(preferences.spokenCharactersPerMinute)).rounded())
            if characters == nil || estimate > (characters ?? 0) { return (.estimated, max(characters ?? 0, estimate)) }
        }
        if let characters, characters > 0 { return (.observed, characters) }
        if failure != .secure, preferences.estimateWhenUnavailable {
            return (.estimated, Int((seconds / 60 * Double(preferences.spokenCharactersPerMinute)).rounded()))
        }
        if let characters, failure == nil { return (.observed, characters) }
        return (.unavailable, nil)
    }
    private func refreshDisplay() {
        var display = ledger
        for current in live.values {
            let (source, count) = selection(characters: current.characters, failure: current.failure, seconds: current.seconds)
            display.record(at: current.at, seconds: current.seconds, characters: count, source: source, failure: current.failure)
        }
        displayLedger = display
        if let current = activeID.flatMap({ live[$0] }) ?? live.values.sorted(by: { $0.at < $1.at }).last {
            let (source, count) = selection(characters: current.characters, failure: current.failure, seconds: current.seconds)
            let phase = activeID != nil ? "正在收录" : "正在接收后续文字"
            let coverage = source == .estimated ? "按麦克风时长估算" : (source == .observed ? "已收录，删改不扣回" : "受保护输入框，不统计文字")
            liveSummary = "\(phase) · 本段 \(count.map(String.init) ?? "—") 字 · \(Int(current.seconds)) 秒 · \(coverage)"
        } else { liveSummary = nil; timer?.invalidate(); timer = nil }
    }
    private func accept(_ receipt: PassiveInputObserver.Receipt) {
        guard collectionEnabled, !loadFailed, let current = live.removeValue(forKey: receipt.id), !completedIDs.contains(receipt.id) else { return }
        completedIDs.insert(receipt.id); if completedIDs.count > 512 { completedIDs = [receipt.id] }
        let rollover = activeID == receipt.id && microphoneActive
        if activeID == receipt.id { activeID = nil }
        if receipt.seconds >= 0.3 {
            let received = max(receipt.characters ?? 0, current.characters ?? 0)
            let characters: Int? = received > 0 ? received : receipt.characters
            let (source, count) = selection(characters: characters, failure: receipt.failure, seconds: receipt.seconds)
            ledger.record(at: receipt.startedAt, seconds: receipt.seconds, characters: count, source: source, failure: receipt.failure)
            status = source == .observed ? "本段累计收录 \(count ?? 0) 字 · 后续删改不扣回" :
                (source == .estimated ? "本段按实际麦克风时长估算 · 原输入照常进行" : "受保护输入框 · 未统计文字")
            save()
        }
        isObserving = !live.isEmpty; refreshDisplay()
        if rollover { begin(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) }
    }
    /// Preserve already received input on pause/exit/disconnection. No last-word
    /// correction or synchronous AX read is required on the shutdown path.
    private func preserveReceived() {
        guard !loadFailed else { return }
        var saved = false
        for (id, current) in live where current.seconds >= 0.3 && !completedIDs.contains(id) {
            let (source, count) = selection(characters: current.characters, failure: current.failure, seconds: current.seconds)
            ledger.record(at: current.at, seconds: current.seconds, characters: count, source: source, failure: current.failure)
            completedIDs.insert(id); saved = true
        }
        if saved { save() }
    }
    private func save() {
        generation += 1; let revision = generation, value = ledger, directory = directory
        writes.async { [weak self] in
            do {
                try UsageStatisticsFile.save(value, directory: directory)
                Task { @MainActor [weak self] in guard let self, generation == revision else { return }; self.error = nil }
            } catch { Task { @MainActor [weak self] in
                guard let self, generation == revision else { return }; self.error = "统计尚未保存，请检查本地存储权限。"
            } }
        }
    }
    func flush() async { await withCheckedContinuation { continuation in writes.async { continuation.resume() } } }
    func installFixture(_ value: UsageStatisticsLedger) {
        guard !permitsObservation else { return }; cancel(); ledger = value; displayLedger = value; status = "合成统计预览 · 未连接真实输入"
    }
    func installLiveFixture(characters: Int, seconds: Double, estimated: Bool = false) {
        guard !permitsObservation else { return }
        let id = UUID(); activeID = id; isObserving = true
        live = [id: Live(at: Date(), uptime: ProcessInfo.processInfo.systemUptime - seconds,
                         characters: estimated ? nil : characters, failure: estimated ? .unsupported : nil)]
        refreshDisplay()
    }
}
