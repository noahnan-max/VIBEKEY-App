import Foundation

public enum SmartLightingMode: Int, CaseIterable, Sendable {
    case off = 0, allOn = 1, workMode = 2
    public var title: String {
        switch self { case .off: return "全灭"; case .allOn: return "全亮"; case .workMode: return "工作模式" }
    }
}

public enum SmartLightingState: String, CaseIterable, Sendable {
    case standby, running, awaitingApproval, completed, failed
    public static let agentStates: [Self] = [.standby, .running, .awaitingApproval, .completed, .failed]
    public var title: String {
        switch self {
        case .standby: return "待命"
        case .running: return "Agent 运行中"
        case .awaitingApproval: return "等待你审批"
        case .completed: return "本轮结束提示"
        case .failed: return "Agent 需要处理"
        }
    }
}

public enum SmartLightingFailure: String, Error, Sendable {
    case invalidSnapshot, invalidIntent, connectionChanged, ownershipChanged, cancelled, unavailable, readbackMismatch, transport
}

/// A full lighting readback for one connection generation. Four opaque five-
/// byte work records are retained, not interpreted as physical LED zones.
public struct SmartLightingSnapshot: Equatable, Sendable {
    public let connectionID: UUID
    public let rawPayload: [UInt8]
    public var mode: SmartLightingMode { SmartLightingMode(rawValue: Int(rawPayload[2]))! }
    public var brightness: Int { Int(rawPayload[3]) }
    public var workRecords: [UInt8] { Array(rawPayload[4..<24]) }

    public init(connectionID: UUID, payload: [UInt8]) throws {
        guard payload.count >= 24, SmartLightingMode(rawValue: Int(payload[2])) != nil,
              payload[3] <= 20 else { throw SmartLightingFailure.invalidSnapshot }
        self.connectionID = connectionID; rawPayload = Array(payload.prefix(24))
    }
    public func applying(_ intent: SmartLightingIntent) throws -> Self {
        var bytes = rawPayload; bytes[2] = UInt8(intent.mode.rawValue)
        if let brightness = intent.brightness { bytes[3] = UInt8(brightness) }
        return try Self(connectionID: connectionID, payload: bytes)
    }
    public static func == (left: Self, right: Self) -> Bool {
        // The first two bytes are a field selector/index, not configuration.
        left.connectionID == right.connectionID && left.rawPayload[2..<24].elementsEqual(right.rawPayload[2..<24])
    }
}

public struct SmartLightingIntent: Equatable, Sendable {
    public let mode: SmartLightingMode
    /// Applies only to allOnModeBrightness. Work record levels stay untouched.
    public let brightness: Int?
    public init(mode: SmartLightingMode, brightness: Int? = nil) throws {
        guard brightness.map({ (0...20).contains($0) }) ?? true else { throw SmartLightingFailure.invalidIntent }
        self.mode = mode; self.brightness = brightness
    }
}

public enum SmartLightingPolicy {
    // Host-side transaction limits, NOT physical lamp Hz or firmware timing.
    public static let minimumTransactionInterval: TimeInterval = 1.5
    public static let maximumFeedbackTransactions = 4
    /// Keep one of the same four slots available for a new approval event.
    public static let maximumOrdinaryFeedbackTransactions = 3
    public static let feedbackWindow: TimeInterval = 60
    public static func intent(for state: SmartLightingState, brightness: Int = 8) throws -> SmartLightingIntent? {
        guard (0...20).contains(brightness) else { throw SmartLightingFailure.invalidIntent }
        switch state {
        case .standby: return nil
        case .completed: return try .init(mode: .allOn, brightness: min(4, brightness))
        case .failed: return try .init(mode: .allOn, brightness: min(2, brightness))
        case .awaitingApproval: return try .init(mode: .allOn, brightness: brightness == 0 ? 0 : min(20, brightness + 8))
        case .running: return try .init(mode: .allOn, brightness: min(12, brightness))
        }
    }
    public static func automaticRestoreDelay(for state: SmartLightingState) -> TimeInterval? {
        // Only the visual hint expires; elapsed time never proves task completion.
        // Approval stays until the owner supplies a cleared/expired source state.
        switch state { case .completed: return 1.2; case .failed: return 3; default: return nil }
    }
    public static func priority(for state: SmartLightingState) -> Int {
        switch state {
        case .awaitingApproval: return 100
        case .completed: return 90
        case .failed: return 80
        case .running: return 60
        case .standby: return 0
        }
    }
    public static func description(for state: SmartLightingState) -> String {
        switch state {
        case .standby: return "恢复原灯光"
        case .running: return "按键与旋钮指示灯保持运行亮度"
        case .awaitingApproval: return "提高整体亮度，持续到审批状态清除或过期"
        case .completed: return "收到真实本轮结束事件后，低亮短提示并恢复；不表示整个任务成功"
        case .failed: return "一次更低亮提示后恢复，详情在 Agent 状态中查看"
        }
    }
}

/// May be read from DeviceSession's queue immediately before transport.send.
/// Revocation is irreversible and does not depend on a MainActor callback.
public final class SmartLightingPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    public init() {}
    public var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    public func revoke() { lock.lock(); valid = false; lock.unlock() }
}

public struct SmartLightingWriteStep: Sendable {
    public let frame: Data
    public let expected: SmartLightingSnapshot
    public let target: SmartLightingSnapshot
}

public struct SmartLightingWriteRequest: Sendable {
    public enum Purpose: String, Sendable { case feedback, restore }
    public let operationID: UUID
    public let purpose: Purpose
    public let expected: SmartLightingSnapshot
    public let target: SmartLightingSnapshot
    public let steps: [SmartLightingWriteStep]
    public var connectionID: UUID { expected.connectionID }
    public var frames: [Data] { steps.map(\.frame) }

    public init(expected: SmartLightingSnapshot, target: SmartLightingSnapshot,
                purpose: Purpose, operationID: UUID = UUID()) throws {
        guard expected.connectionID == target.connectionID else { throw SmartLightingFailure.connectionChanged }
        guard expected.workRecords == target.workRecords else { throw SmartLightingFailure.invalidIntent }
        self.expected = expected; self.target = target; self.purpose = purpose; self.operationID = operationID
        var current = expected, result: [SmartLightingWriteStep] = []
        func modeStep() throws {
            guard current.mode != target.mode else { return }
            let next = try current.applying(.init(mode: target.mode))
            result.append(.init(frame: try DeviceControls.lightMode(target.mode.rawValue), expected: current, target: next)); current = next
        }
        func brightnessStep() throws {
            guard current.brightness != target.brightness else { return }
            let next = try current.applying(.init(mode: current.mode, brightness: target.brightness))
            result.append(.init(frame: try DeviceControls.lightBrightness(target.brightness), expected: current, target: next)); current = next
        }
        // Turn off first when restoring an originally dark setting. Otherwise
        // prepare the supported all-on brightness before changing the mode.
        if target.mode == .off { try modeStep(); try brightnessStep() }
        else { try brightnessStep(); try modeStep() }
        steps = result
    }
}

/// An adapter must retain the last COMPLETE hardware readback if a later frame
/// fails. A sent/acknowledged frame alone must not be put in lastReadback.
public struct SmartLightingApplyError: Error, Sendable {
    public let reason: SmartLightingFailure
    public let lastReadback: SmartLightingSnapshot?
    public init(_ reason: SmartLightingFailure, lastReadback: SmartLightingSnapshot? = nil) {
        self.reason = reason; self.lastReadback = lastReadback
    }
}
