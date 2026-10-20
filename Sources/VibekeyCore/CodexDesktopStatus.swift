import Foundation
import CryptoKit

/// Durable evidence that a specific Codex turn ended. It is used only to
/// retire matching pending approvals; its age must never replay a light hint.
public struct CodexDesktopTurnClosure: Equatable, Sendable {
    public let sessionHash: String
    public let turnHash: String
    public let occurredAt: TimeInterval
    public let state: AgentSignalState
    public init(sessionHash: String, turnHash: String, occurredAt: TimeInterval, state: AgentSignalState) {
        self.sessionHash = sessionHash; self.turnHash = turnHash; self.occurredAt = occurredAt; self.state = state
    }
    public func validate() throws {
        let digest: (String) -> Bool = { value in
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard digest(sessionHash), digest(turnHash), occurredAt.isFinite, occurredAt > 0,
              [.turnCompleted, .failed, .interrupted].contains(state) else { throw AgentSignalError.invalidEvent }
    }
}

/// A compatibility adapter for one observed Desktop rollout version. These
/// records are not a stable Codex API and never supply approval state.
public struct CodexDesktopStatusBatch: Equatable, Sendable {
    public let events: [AgentSignal]
    public let observedAt: Date
    public let sourceAvailable: Bool
    public let inspectedSessions: Int
    public let statusText: String
    public let closedTurns: [CodexDesktopTurnClosure]
    public init(events: [AgentSignal], observedAt: Date, sourceAvailable: Bool,
                inspectedSessions: Int, statusText: String, closedTurns: [CodexDesktopTurnClosure] = []) {
        self.events = events; self.observedAt = observedAt; self.sourceAvailable = sourceAvailable
        self.inspectedSessions = inspectedSessions; self.statusText = statusText
        self.closedTurns = closedTurns
    }
}

public protocol CodexDesktopStatusReading: Sendable {
    func poll(at: Date) throws -> CodexDesktopStatusBatch
}

public enum CodexDesktopStatusIdentity {
    public static func digest(_ values: String...) -> String { digest(values) }
    public static func digest(_ values: [String]) -> String {
        SHA256.hash(data: Data(values.joined(separator: "\0").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0)
        }
    }
}

public struct CodexDesktopSessionHeader: Equatable, Sendable {
    public let sessionID: String
    public static let supportedVersion = "0.163.0-alpha.10.2"
}

public struct CodexDesktopEventMetadata: Equatable, Sendable {
    public enum Kind: String, Decodable, Sendable {
        case started = "task_started", completed = "task_complete", aborted = "turn_aborted"
        case itemCompleted = "item_completed", tokenCount = "token_count"
    }
    public let kind: Kind
    public let turnID: String?
    public let occurredAt: TimeInterval
    /// Only presence is decoded. Error messages and details remain unread.
    public let hasError: Bool
}

public enum CodexDesktopStatusDecoder {
    private struct HeaderEnvelope: Decodable {
        let type: String
        let payload: Header?
        enum CodingKeys: String, CodingKey { case type, payload }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            type = try values.decode(String.self, forKey: .type)
            payload = type == "session_meta" ? try values.decode(Header.self, forKey: .payload) : nil
        }
    }
    private struct Header: Decodable {
        let id: String
        let source: String
        let originator: String
        let cliVersion: String
        enum CodingKeys: String, CodingKey { case id, source, originator; case cliVersion = "cli_version" }
    }
    private struct EventEnvelope: Decodable {
        let timestamp: String?
        let payload: Event?
        enum CodingKeys: String, CodingKey { case type, timestamp, payload }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let type = try values.decode(String.self, forKey: .type)
            if type == "event_msg" {
                timestamp = try values.decode(String.self, forKey: .timestamp)
                payload = try values.decode(Event.self, forKey: .payload)
            } else { timestamp = nil; payload = nil }
        }
    }
    private struct Event: Decodable {
        let kind: CodexDesktopEventMetadata.Kind?
        let turnID: String?
        let hasError: Bool
        enum CodingKeys: String, CodingKey { case type, error; case turnID = "turn_id" }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            kind = CodexDesktopEventMetadata.Kind(rawValue: try values.decode(String.self, forKey: .type))
            // Unsupported event bodies, item payloads, prompts, tool arguments
            // and last_agent_message are deliberately not decoded.
            guard kind != nil else { turnID = nil; hasError = false; return }
            turnID = try values.decodeIfPresent(String.self, forKey: .turnID)
            if values.contains(.error) { hasError = try !values.decodeNil(forKey: .error) }
            else { hasError = false }
        }
    }
    public static func header(from data: Data) throws -> CodexDesktopSessionHeader? {
        let envelope = try JSONDecoder().decode(HeaderEnvelope.self, from: data)
        guard let header = envelope.payload, header.source == "vscode", header.originator == "Codex Desktop",
              header.cliVersion == CodexDesktopSessionHeader.supportedVersion,
              CodexDesktopStatusIdentity.validIdentifier(header.id) else { return nil }
        return CodexDesktopSessionHeader(sessionID: header.id)
    }
    public static func event(from data: Data) throws -> CodexDesktopEventMetadata? {
        let envelope = try JSONDecoder().decode(EventEnvelope.self, from: data)
        guard let event = envelope.payload, let kind = event.kind, let timestamp = envelope.timestamp else { return nil }
        if let turn = event.turnID, !CodexDesktopStatusIdentity.validIdentifier(turn) { throw AgentSignalError.invalidEvent }
        if kind == .started || kind == .completed || kind == .aborted {
            guard event.turnID != nil else { throw AgentSignalError.invalidEvent }
        }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = format.date(from: timestamp)
        if date == nil { format.formatOptions = [.withInternetDateTime]; date = format.date(from: timestamp) }
        guard let time = date?.timeIntervalSince1970, time.isFinite, time > 0 else { throw AgentSignalError.invalidEvent }
        return CodexDesktopEventMetadata(kind: kind, turnID: event.turnID, occurredAt: time, hasError: event.hasError)
    }
}
