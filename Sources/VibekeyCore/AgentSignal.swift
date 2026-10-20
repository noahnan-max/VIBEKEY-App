import Foundation

public enum AgentSignalSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude
    public var id: String {rawValue}
    public var title: String {self == .codex ? "Codex" : "Claude Code"}
}
public enum AgentSignalState: String, Codable, CaseIterable, Identifiable, Sendable {
    case running, approvalRequired, attentionRequired, stopProposed, turnCompleted, taskCompleted, failed, interrupted, ended
    public var id: String {rawValue}
    public var title: String {
        switch self {
        case .running: return "正在工作"
        case .approvalRequired: return "需要审批"
        case .attentionRequired: return "需要核对"
        case .stopProposed: return "收尾待确认"
        case .turnCompleted: return "本轮结束"
        case .taskCompleted: return "任务完成"
        case .failed: return "本轮失败"
        case .interrupted: return "本轮中断"
        case .ended: return "会话结束"
        }
    }
    public var lifetime: TimeInterval {
        switch self {case .stopProposed,.turnCompleted,.taskCompleted: return 8; case .failed,.interrupted: return 30; case .ended: return 0; default: return 300}
    }
    fileprivate var priority: Int {
        switch self {case .approvalRequired: return 6; case .attentionRequired: return 5; case .failed,.interrupted: return 4; case .taskCompleted: return 3; case .turnCompleted: return 2; case .running,.stopProposed: return 1; case .ended: return 0}
    }
}

/// Only identifiers, enums and time cross the boundary. No tool arguments,
/// transcript paths, prompt/assistant text or raw upstream JSON are permitted.
public struct AgentSignal: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public let source: AgentSignalSource
    public let state: AgentSignalState
    public let sessionHash: String
    public let eventID: String
    public let sequence: UInt64
    public let occurredAt: TimeInterval
    public let simulation: Bool
    public let requestHash: String?
    public let resolvesRequestHash: String?
    public let turnHash: String?
    public let endsTurn: Bool
    public init(source: AgentSignalSource, state: AgentSignalState, sessionHash: String, eventID: String,
                sequence: UInt64, occurredAt: TimeInterval, simulation: Bool = false,
                requestHash: String? = nil, resolvesRequestHash: String? = nil,
                turnHash: String? = nil, endsTurn: Bool = false) {
        self.source = source; self.state = state; self.sessionHash = sessionHash; self.eventID = eventID
        self.sequence = sequence; self.occurredAt = occurredAt; self.simulation = simulation
        self.requestHash = requestHash; self.resolvesRequestHash = resolvesRequestHash
        self.turnHash = turnHash; self.endsTurn = endsTurn
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, source, state, sessionHash, eventID, sequence, occurredAt, simulation, requestHash, resolvesRequestHash, turnHash, endsTurn
    }
    private struct Key: CodingKey {let stringValue:String;var intValue:Int? {nil};init?(stringValue:String){self.stringValue=stringValue};init?(intValue:Int){return nil}}
    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: Key.self)
        guard keys.allKeys.allSatisfy({Set(CodingKeys.allCases.map(\.rawValue)).contains($0.stringValue)}) else {throw AgentSignalError.invalidEvent}
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        source = try values.decode(AgentSignalSource.self, forKey: .source)
        state = try values.decode(AgentSignalState.self, forKey: .state)
        sessionHash = try values.decode(String.self, forKey: .sessionHash)
        eventID = try values.decode(String.self, forKey: .eventID)
        sequence = try values.decode(UInt64.self, forKey: .sequence)
        occurredAt = try values.decode(TimeInterval.self, forKey: .occurredAt)
        simulation = try values.decode(Bool.self, forKey: .simulation)
        requestHash = try values.decodeIfPresent(String.self, forKey: .requestHash)
        resolvesRequestHash = try values.decodeIfPresent(String.self, forKey: .resolvesRequestHash)
        turnHash = try values.decodeIfPresent(String.self, forKey: .turnHash)
        endsTurn = try values.decodeIfPresent(Bool.self, forKey: .endsTurn) ?? false
    }
    public func validate() throws {
        guard schemaVersion == 1, sequence > 0, occurredAt.isFinite, occurredAt > 0,
              Self.digest(sessionHash), Self.digest(eventID), requestHash.map(Self.digest) ?? true,
              resolvesRequestHash.map(Self.digest) ?? true, turnHash.map(Self.digest) ?? true,
              !endsTurn || (source == .codex && turnHash != nil && [.turnCompleted,.failed,.interrupted].contains(state)),
              simulation || state != .taskCompleted else {throw AgentSignalError.invalidEvent}
        // There is no supported post-commit task-completion source in this
        // release. A Claude TaskCompleted hook is only a proposal and is ignored.
    }
    private static func digest(_ value:String)->Bool {value.utf8.count == 64 && value.utf8.allSatisfy{(48...57).contains($0) || (97...102).contains($0)}}
}
public enum AgentSignalError: Error {case invalidEvent, capacityExceeded}

public struct AgentSignalSnapshot: Equatable, Sendable {
    public let state: AgentSignalState?
    public let source: AgentSignalSource?
    public let selectedEventID: String?
    public let isSimulation: Bool
    public let activeSessionCount: Int
    public let lastEventAt: Date?
    public let staleSessionCount: Int
    public let unresolvedApprovalCount: Int
    public static let unknown = AgentSignalSnapshot(state:nil,source:nil,selectedEventID:nil,isSimulation:false,activeSessionCount:0,lastEventAt:nil,staleSessionCount:0,unresolvedApprovalCount:0)
}

public struct AgentSignalAggregator {
    public static let maximumSessions = 4096
    private struct Record {
        var latest: AgentSignal
        var pending: [String: AgentSignal] = [:]
        var uncertainApproval = false
        var seen: [String] = []
    }
    private var records: [String: Record] = [:]
    public init() {}
    @discardableResult public mutating func ingest(_ event: AgentSignal, now: Date) throws -> Bool {
        try event.validate()
        let time = now.timeIntervalSince1970
        guard time.isFinite, event.occurredAt <= time else {return false}
        let key = event.source.rawValue + ":" + event.sessionHash + (event.simulation ? ":simulation" : ":real")
        if let prior = records[key] {
            guard prior.latest.state != .ended, event.sequence > prior.latest.sequence,
                  event.occurredAt >= prior.latest.occurredAt, !prior.seen.contains(event.eventID) else {return false}
        } else if records.count >= Self.maximumSessions {throw AgentSignalError.capacityExceeded}
        var row = records[key] ?? Record(latest:event)
        if event.state == .ended {row.pending.removeAll();row.uncertainApproval = false}
        else {
            // A real final turn record closes only approvals from that exact
            // turn. Tool completion and another turn never clear a request.
            if event.endsTurn, let turn = event.turnHash {
                row.pending = row.pending.filter { $0.value.turnHash != turn }
            }
            if let resolved = event.resolvesRequestHash {row.pending.removeValue(forKey:resolved)}
            if event.state == .approvalRequired {
                let request = event.requestHash ?? ("unknown:"+event.eventID)
                if row.pending[request] == nil {row.pending[request] = event}
                if event.requestHash == nil {row.uncertainApproval = true}
            } else if !row.pending.isEmpty {
                // A different tool result, a new prompt or a Stop does not prove
                // that an outstanding approval was answered.
                row.uncertainApproval = true
            }
            if row.pending.isEmpty {row.uncertainApproval = false}
        }
        row.latest = event;row.seen.append(event.eventID)
        if row.seen.count > 64 {row.seen.removeFirst(row.seen.count-64)}
        records[key] = row
        return true
    }
    public func latestEvent(for source: AgentSignalSource) -> AgentSignal? {
        records.values.map(\.latest).filter{$0.source == source && !$0.simulation}.max{$0.sequence < $1.sequence}
    }
    public func snapshot(at now: Date, source: AgentSignalSource? = nil) -> AgentSignalSnapshot {
        let time = now.timeIntervalSince1970
        guard time.isFinite else {return .unknown}
        let matching = records.values.filter {source == nil || $0.latest.source == source}
        let real = matching.filter{!$0.latest.simulation}
        let all = real.isEmpty ? Array(matching) : Array(real)
        var candidates: [(AgentSignalState,AgentSignal)] = []
        var stale = 0, unresolved = 0
        for row in all {
            let event = row.latest
            guard event.state != .ended else {continue}
            if !row.pending.isEmpty {
                unresolved += row.pending.count
                // An upstream hook without a request ID cannot distinguish a
                // second request from a replay. Preserve each receipt, but do
                // not refresh the first uncorrelated warning or its TTL.
                let unknown = row.pending.values.filter{$0.requestHash == nil}.min{$0.sequence < $1.sequence}
                let eligible = unknown.map{[$0]} ?? Array(row.pending.values)
                let fresh = eligible.filter {time >= $0.occurredAt && time-$0.occurredAt < AgentSignalState.approvalRequired.lifetime}
                if let approval = fresh.max(by:{$0.sequence < $1.sequence}) {
                    candidates.append((row.uncertainApproval ? .attentionRequired : .approvalRequired,approval))
                } else {stale += 1}
                continue
            }
            let age = time-event.occurredAt
            if age >= 0 && age < event.state.lifetime {candidates.append((event.state,event))}
            else {stale += 1}
        }
        // An expired approval keeps its own session unknown. It does not mask
        // a fresh, independently identified turn result from another session.
        let chosen = candidates.max {left,right in left.0.priority == right.0.priority ? left.1.sequence < right.1.sequence : left.0.priority < right.0.priority}
        let last = all.map(\.latest.occurredAt).max().map{Date(timeIntervalSince1970:$0)}
        return AgentSignalSnapshot(state:chosen?.0,source:chosen?.1.source,selectedEventID:chosen?.1.eventID,isSimulation:chosen?.1.simulation ?? false,
            activeSessionCount:candidates.count,lastEventAt:last,staleSessionCount:stale,unresolvedApprovalCount:unresolved)
    }
}
