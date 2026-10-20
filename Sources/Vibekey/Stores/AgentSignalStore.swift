import Foundation
import VibekeyCore
import Combine
import CryptoKit
import Darwin

/// Reads VIBEKEY's private hook inbox and an explicitly supplied, bounded
/// Desktop status reader. Only typed state metadata enters the aggregator.
@MainActor final class AgentSignalStore: ObservableObject {
    @Published private(set) var snapshot = AgentSignalSnapshot.unknown
    @Published private(set) var physicalSnapshot = AgentSignalSnapshot.unknown
    @Published private(set) var sourceSnapshots: [AgentSignalSource: AgentSignalSnapshot] = [:]
    @Published private(set) var lastEvents: [AgentSignalSource: AgentSignal] = [:]
    @Published private(set) var errorMessage: String?
    @Published private(set) var completionProposedCount = 0
    /// Historical installation receipt only; never a real Agent event.
    @Published private(set) var configuredSources: Set<AgentSignalSource> = []
    @Published private(set) var simulationTitle: String?
    @Published private(set) var desktopStatusText = "Codex 桌面状态观察未启用。"
    @Published private(set) var observedSources: Set<AgentSignalSource> = []
    let directory: URL
    private let clock: () -> Date
    private let desktopReader: CodexDesktopStatusReading?
    private var nativeEvents: [AgentSignal] = []
    private var desktopEvents: [AgentSignal] = []
    private var closedTurns: [String: CodexDesktopTurnClosure] = [:]
    private var desktopTask: Task<Void, Never>?
    private var desktopWorker: Task<CodexDesktopStatusBatch, Error>?
    private var aggregator = AgentSignalAggregator()
    // One bounded, successfully checked file. Never skip the file's security
    // checks based on mtime/inode, and never cache a failed decode or read.
    private var cachedInboxData: Data?
    private var hasCachedInbox = false
    private var cachedEvaluationTime: TimeInterval?
    private var clockRejectedInbox = false
    private(set) var inboxDecodeCount: UInt64 = 0
    private var cachedSetupData: Data?
    private var hasCachedSetup = false
    private(set) var setupDecodeCount: UInt64 = 0
    private var simulation: AgentSignal?
    private var simulationSequence: UInt64 = 0
    private var timer: Timer?
    private var lifetime = UUID()
    private struct Inbox: Decodable {
        let schemaVersion: Int
        let events: [AgentSignal]
        let completionProposedCount: Int
        private struct Key: CodingKey {let stringValue:String;var intValue:Int? {nil};init?(stringValue:String){self.stringValue=stringValue};init?(intValue:Int){return nil}}
        init(from decoder:Decoder) throws {
            let values = try decoder.container(keyedBy:Key.self)
            guard Set(values.allKeys.map(\.stringValue)) == ["schemaVersion","events","completionProposedCount"] else {throw SignalReadError.invalid}
            schemaVersion = try values.decode(Int.self,forKey:Key(stringValue:"schemaVersion")!)
            events = try values.decode([AgentSignal].self,forKey:Key(stringValue:"events")!)
            completionProposedCount = try values.decode(Int.self,forKey:Key(stringValue:"completionProposedCount")!)
        }
    }
    private struct SetupReceipt: Decodable {
        let schemaVersion: Int
        let sources: [AgentSignalSource]
        let installedAt: Double
        private struct Key: CodingKey {let stringValue:String;var intValue:Int? {nil};init?(stringValue:String){self.stringValue=stringValue};init?(intValue:Int){return nil}}
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Key.self)
            guard Set(values.allKeys.map(\.stringValue)) == ["schemaVersion", "sources", "installedAt"] else {throw SignalReadError.invalid}
            schemaVersion = try values.decode(Int.self, forKey: Key(stringValue: "schemaVersion")!)
            sources = try values.decode([AgentSignalSource].self, forKey: Key(stringValue: "sources")!)
            installedAt = try values.decode(Double.self, forKey: Key(stringValue: "installedAt")!)
        }
    }
    init(directory: URL? = nil, clock: @escaping () -> Date = Date.init, desktopReader: CodexDesktopStatusReading? = nil) {
        self.directory = directory ?? VibekeyPaths.applicationSupport.appendingPathComponent("AgentSignals", isDirectory:true)
        self.clock = clock; self.desktopReader = desktopReader
    }
    func start() {
        guard timer == nil else {return}
        lifetime = UUID();let id = lifetime
        let timer = Timer(timeInterval:1,repeats:true) { [weak self] _ in
            guard let owner = self else {return}
            Task { @MainActor in guard owner.lifetime == id,owner.timer != nil else {return};owner.refresh() }
        }
        self.timer = timer;RunLoop.main.add(timer,forMode:.common);refresh()
    }
    func stop() {
        lifetime = UUID();timer?.invalidate();timer = nil
        clearCachedPresentation()
        closedTurns = [:]
        clearConfigurationCache()
        if errorMessage != nil {errorMessage = nil}
    }
    func refresh() {
        refreshConfiguredSources()
        do {
            // readInbox still checks every path/permission/type/size on EVERY
            // poll, even when the bytes ultimately equal the previous poll.
            let data = try readInbox()
            let now = clock()
            let time = now.timeIntervalSince1970
            let sameObservedBatch = (cachedEvaluationTime != nil || clockRejectedInbox) && data == cachedInboxData
            if !time.isFinite || (sameObservedBatch && (clockRejectedInbox || cachedEvaluationTime.map({time < $0}) == true)) {
                // Once this batch is rejected for a clock rollback, repeating
                // its bytes must not resurrect an already-expired event.
                clearCachedPresentation()
                cachedInboxData = data;clockRejectedInbox = true
                let message = "系统时间已变化，等待新的 Agent 事件。"
                if errorMessage != message {errorMessage = message}
                return
            }
            if !hasCachedInbox || data != cachedInboxData {
                var next = AgentSignalAggregator(), proposedCount = 0
                var received: [AgentSignal] = []
                var cacheable = time.isFinite
                if let data {
                    inboxDecodeCount &+= 1
                    let inbox = try JSONDecoder().decode(Inbox.self,from:data)
                    guard inbox.schemaVersion == 1,inbox.events.count <= AgentSignalAggregator.maximumSessions*2,
                          inbox.completionProposedCount >= 0 else {throw SignalReadError.invalid}
                    for event in inbox.events.sorted(by:{$0.sequence < $1.sequence}) {
                        guard !event.simulation else {throw SignalReadError.invalid}
                        // ingest(now:) ignores a future event. Do not freeze
                        // that temporary omission when its time later arrives.
                        if event.occurredAt > time {cacheable = false}
                        try next.ingest(event,now:now)
                    }
                    received = inbox.events
                    proposedCount = inbox.completionProposedCount
                }
                nativeEvents = received
                markObservedSources(received.map(\.source))
                aggregator = next;cachedInboxData = data;hasCachedInbox = cacheable;clockRejectedInbox = false
                if completionProposedCount != proposedCount {completionProposedCount = proposedCount}
                let events = Dictionary(uniqueKeysWithValues:AgentSignalSource.allCases.compactMap {source in
                    next.latestEvent(for:source).map{(source,$0)}
                })
                if lastEvents != events {lastEvents = events}
            }
            // This is the last successful evaluation, including cache hits,
            // rather than only the time the JSON was first decoded.
            cachedEvaluationTime = time
            if errorMessage != nil {errorMessage = nil}
            if desktopReader != nil { try rebuildMergedEvents(at: now) }
            updatePresentation(at:now)
            pollDesktop(at: now)
        } catch {
            clearCachedPresentation()
            let message = "Agent事件接入暂不可用，当前状态未知。请检查接入文件。"
            if errorMessage != message {errorMessage = message}
        }
    }
    private func clearCachedPresentation() {
        desktopTask?.cancel(); desktopTask = nil; desktopWorker?.cancel(); desktopWorker = nil
        nativeEvents = []; desktopEvents = []
        cachedInboxData = nil;hasCachedInbox = false;cachedEvaluationTime = nil;clockRejectedInbox = false
        aggregator = AgentSignalAggregator();simulation = nil
        if simulationTitle != nil {simulationTitle = nil}
        if snapshot != .unknown {snapshot = .unknown}
        if physicalSnapshot != .unknown {physicalSnapshot = .unknown}
        if !sourceSnapshots.isEmpty {sourceSnapshots = [:]}
        if !lastEvents.isEmpty {lastEvents = [:]}
        if completionProposedCount != 0 {completionProposedCount = 0}
        if !observedSources.isEmpty {observedSources = []}
    }
    private func markObservedSources(_ sources:[AgentSignalSource]) {
        let next=observedSources.union(sources)
        if next != observedSources {observedSources=next}
    }
    private func setDesktopStatus(_ text:String) {
        if desktopStatusText != text {desktopStatusText=text}
    }
    private func rebuildMergedEvents(at now: Date) throws {
        var next = AgentSignalAggregator()
        let candidates = (nativeEvents + desktopEvents).filter { event in
            guard event.source == .codex, !event.endsTurn, event.state != .ended, let turn = event.turnHash,
                  let proof = closedTurns[event.sessionHash + ":" + turn],
                  proof.occurredAt <= now.timeIntervalSince1970, event.occurredAt <= proof.occurredAt else { return true }
            return false
        }
        let combined = candidates.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.eventID < $1.eventID
        }
        // Each source has its own sequence space. Remap only in memory, after
        // ordering by real source time, so one source cannot starve future hooks.
        for (index, event) in combined.enumerated() {
            try event.validate()
            let value = AgentSignal(source: event.source, state: event.state, sessionHash: event.sessionHash,
                eventID: event.eventID, sequence: UInt64(index + 1), occurredAt: event.occurredAt,
                simulation: event.simulation, requestHash: event.requestHash,
                resolvesRequestHash: event.resolvesRequestHash, turnHash: event.turnHash, endsTurn: event.endsTurn)
            try next.ingest(value, now: now)
        }
        aggregator = next
        let events = Dictionary(uniqueKeysWithValues: AgentSignalSource.allCases.compactMap { source in
            next.latestEvent(for: source).map { (source, $0) }
        })
        if lastEvents != events { lastEvents = events }
    }
    private func pollDesktop(at now: Date) {
        guard let desktopReader, desktopTask == nil else { return }
        let owner = lifetime
        let worker = Task.detached(priority: .utility) { try desktopReader.poll(at: now) }
        desktopWorker = worker
        desktopTask = Task { [weak self] in
            let result = await worker.result
            guard let self, !Task.isCancelled, lifetime == owner else { return }
            desktopTask = nil; desktopWorker = nil
            guard errorMessage == nil else { return }
            switch result {
            case .success(let batch):
                setDesktopStatus(batch.statusText)
                desktopEvents = batch.events
                markObservedSources(batch.events.map(\.source))
                do {
                    for proof in batch.closedTurns {
                        try proof.validate()
                        guard proof.occurredAt <= clock().timeIntervalSince1970 else { continue }
                        let key = proof.sessionHash + ":" + proof.turnHash
                        if closedTurns[key].map({ $0.occurredAt > proof.occurredAt }) != true { closedTurns[key] = proof }
                    }
                    if closedTurns.count > 1_024 {
                        closedTurns = Dictionary(uniqueKeysWithValues:closedTurns.sorted { $0.value.occurredAt > $1.value.occurredAt }.prefix(1_024).map { ($0.key,$0.value) })
                    }
                } catch {
                    desktopEvents = []
                    setDesktopStatus("Codex 终态证据格式未确认，已保留真实回调状态。")
                }
            case .failure:
                setDesktopStatus("Codex 桌面状态暂不可用；审批回调仍独立检查。")
                desktopEvents = []
            }
            do { try rebuildMergedEvents(at: clock()); updatePresentation(at: clock()) }
            catch {
                desktopEvents = []
                setDesktopStatus("Codex 桌面状态格式未确认，已保留真实回调状态。")
                if (try? rebuildMergedEvents(at: clock())) != nil { updatePresentation(at: clock()) }
            }
        }
    }
    private func refreshConfiguredSources() {
        do {
            let data = try readLocalFile("setup.json")
            guard !hasCachedSetup || data != cachedSetupData else {return}
            var sources: Set<AgentSignalSource> = []
            if let data {
                setupDecodeCount &+= 1
                let receipt = try JSONDecoder().decode(SetupReceipt.self, from: data)
                guard receipt.schemaVersion == 1, receipt.installedAt.isFinite, receipt.installedAt > 0 else {throw SignalReadError.invalid}
                sources = Set(receipt.sources)
            }
            cachedSetupData = data;hasCachedSetup = true
            if configuredSources != sources {configuredSources = sources}
        } catch {clearConfigurationCache()}
    }
    private func clearConfigurationCache() {
        cachedSetupData = nil;hasCachedSetup = false
        if !configuredSources.isEmpty {configuredSources = []}
    }
    func simulate(state: AgentSignalState, source: AgentSignalSource = .codex) {
        guard errorMessage == nil else {return}
        simulationSequence += 1
        let hash = Self.hash(UUID().uuidString)
        let now = clock()
        simulation = AgentSignal(source:source,state:state,sessionHash:hash,eventID:Self.hash("event:"+hash),
                                 sequence:simulationSequence,occurredAt:now.timeIntervalSince1970,simulation:true,
                                 requestHash:state == .approvalRequired ? hash : nil)
        let title = "模拟 · "+source.title+" · "+state.title
        if simulationTitle != title {simulationTitle = title}
        updatePresentation(at:now)
    }
    private func updatePresentation(at now: Date) {
        let real = aggregator.snapshot(at:now)
        if physicalSnapshot != real {physicalSnapshot = real}
        let sources = Dictionary(uniqueKeysWithValues:AgentSignalSource.allCases.map{($0,aggregator.snapshot(at:now,source:$0))})
        if sourceSnapshots != sources {sourceSnapshots = sources}
        var display = real
        if let simulation {
            if now.timeIntervalSince1970-simulation.occurredAt >= min(8,simulation.state.lifetime) {
                self.simulation = nil
                if simulationTitle != nil {simulationTitle = nil}
            } else if real.state == nil,real.unresolvedApprovalCount == 0,errorMessage == nil {
                var demo = AgentSignalAggregator();_ = try? demo.ingest(simulation,now:now)
                display = demo.snapshot(at:now)
            }
        }
        if snapshot != display {snapshot = display}
    }
    private static func hash(_ value:String)->String {SHA256.hash(data:Data(value.utf8)).map{String(format:"%02x",$0)}.joined()}
    private enum SignalReadError: Error {case unsafe,invalid,bridgeFailed}
    private func readInbox() throws -> Data? {
        try readLocalFile("inbox.json", rejectsBridgeFailure: true)
    }
    private func readLocalFile(_ name: String, rejectsBridgeFailure: Bool = false) throws -> Data? {
        let files = FileManager.default
        guard directory.isFileURL,directory.path.hasPrefix("/") else {throw SignalReadError.unsafe}
        var ancestor = directory
        while true {
            if (try? files.destinationOfSymbolicLink(atPath:ancestor.path)) != nil {throw SignalReadError.unsafe}
            if files.fileExists(atPath:ancestor.path),
               (try files.attributesOfItem(atPath:ancestor.path))[.type] as? FileAttributeType != .typeDirectory {throw SignalReadError.unsafe}
            if ancestor.path == "/" {break};ancestor.deleteLastPathComponent()
        }
        guard files.fileExists(atPath:directory.path) else {return nil}
        let info = try files.attributesOfItem(atPath:directory.path)
        guard info[.type] as? FileAttributeType == .typeDirectory,
              (info[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              (info[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else {throw SignalReadError.unsafe}
        if rejectsBridgeFailure {
            let failure = directory.appendingPathComponent("bridge-error.json")
            if files.fileExists(atPath:failure.path) || (try? files.destinationOfSymbolicLink(atPath:failure.path)) != nil {throw SignalReadError.bridgeFailed}
        }
        let path = directory.appendingPathComponent(name)
        let fd = Darwin.open(path.path,O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {if errno == ENOENT {return nil};throw SignalReadError.unsafe}
        defer {_ = Darwin.close(fd)}
        var attributes = stat()
        guard fstat(fd,&attributes) == 0,attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              attributes.st_nlink == 1,attributes.st_uid == geteuid(),attributes.st_mode & 0o7777 == 0o600,
              attributes.st_size <= 2*1024*1024 else {throw SignalReadError.unsafe}
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        guard let data = try handle.read(upToCount:2*1024*1024+1),data.count <= 2*1024*1024 else {throw SignalReadError.invalid}
        return data
    }
    deinit {timer?.invalidate(); desktopTask?.cancel(); desktopWorker?.cancel()}
}
