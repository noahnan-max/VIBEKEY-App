import Foundation

/// Uses the system application, so saved workflows remain compatible with the
/// existing openApp schema. Rotary selection is provided by the radial host.
public enum WindowOverviewAction {
    public static let bundleIdentifier = "com.apple.exposelauncher"
    public static var step: WorkflowStep { WorkflowStep(kind: .openApp, argument: bundleIdentifier) }
    public static func matches(_ steps: [WorkflowStep]) -> Bool {
        steps.count == 1 && steps[0].kind == .openApp && steps[0].argument == bundleIdentifier
    }
    public static var item: RadialMenuItem { RadialMenuItem(name: "窗口总览", steps: [step]) }
}

/// Only transient system identity and geometry. No window names or content.
public struct WindowOverviewTarget: Equatable {
    public let id: UInt32
    public let frame: CGRect
    public init(id: UInt32, frame: CGRect) { self.id = id; self.frame = frame }
    public var isValid: Bool {
        id > 0 && [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width >= 16 && frame.height >= 16
    }
}

public struct WindowOverviewSelection {
    public private(set) var targets: [WindowOverviewTarget] = []
    public private(set) var selectedID: UInt32?
    public init() {}
    public mutating func begin(_ values: [WindowOverviewTarget]) {
        targets = Self.ordered(values); selectedID = targets.first?.id
    }
    public mutating func rotate(_ delta: Int, current values: [WindowOverviewTarget]) -> WindowOverviewTarget? {
        let refreshed = Self.ordered(values)
        guard !refreshed.isEmpty else { targets = []; selectedID = nil; return nil }
        let index = refreshed.firstIndex { $0.id == selectedID }
        let next = index.map { ($0 + delta % refreshed.count + refreshed.count) % refreshed.count }
            ?? (delta < 0 ? refreshed.count - 1 : 0)
        targets = refreshed; selectedID = refreshed[next].id; return refreshed[next]
    }
    /// Confirmation re-resolves the exact chosen identity, never an old index.
    public func resolve(_ id: UInt32, current values: [WindowOverviewTarget]) -> WindowOverviewTarget? {
        guard selectedID == id else { return nil }
        let matches = values.filter { $0.id == id && $0.isValid }
        return matches.count == 1 ? matches[0] : nil
    }
    public mutating func end() { targets = []; selectedID = nil }
    private static func ordered(_ values: [WindowOverviewTarget]) -> [WindowOverviewTarget] {
        let counts = Dictionary(grouping: values, by: \.id)
        return values.filter { $0.isValid && counts[$0.id]?.count == 1 }.sorted {
            let firstRow = floor($0.frame.midY / 80), secondRow = floor($1.frame.midY / 80)
            if firstRow != secondRow { return firstRow < secondRow }
            if $0.frame.midX != $1.frame.midX { return $0.frame.midX < $1.frame.midX }
            return $0.id < $1.id
        }
    }
}

public enum WindowOverviewInputEffect: Equatable {
    case rotate(Int), confirm(UInt32), cancel
}
public struct WindowOverviewInputResult: Equatable {
    public let consumed: Bool
    public let effect: WindowOverviewInputEffect?
}

/// Retains ownership of releases after cancellation, just like the wheel.
public struct WindowOverviewInputRouter {
    public private(set) var active = false
    private var owned: Set<String> = []
    private var confirmationID: UInt32?
    private var cancelTriggerID = "key.2"
    public init() {}
    public mutating func begin(cancelTriggerID: String) {
        active = true; confirmationID = nil; self.cancelTriggerID = cancelTriggerID
    }
    public mutating func end() { active = false; confirmationID = nil }
    public mutating func handle(_ id: String, pressed: Bool, selectedID: UInt32?, eligible: Bool) -> WindowOverviewInputResult {
        if !pressed, owned.remove(id) != nil {
            if active, !eligible { end(); return .init(consumed: true, effect: .cancel) }
            let candidate = confirmationID
            if id == "knob.press" { confirmationID = nil }
            var effect: WindowOverviewInputEffect?
            if active, eligible, id == "knob.press", let candidate, candidate == selectedID { effect = .confirm(candidate) }
            return .init(consumed: true, effect: effect)
        }
        guard active, HardwareTrigger.available.contains(where: { $0.id == id }) else { return .init(consumed: false, effect: nil) }
        if pressed { owned.insert(id) }
        guard eligible else { end(); return .init(consumed: true, effect: .cancel) }
        guard pressed else { return .init(consumed: true, effect: nil) }
        if id == "knob.left" || id == "knob.right" { return .init(consumed: true, effect: .rotate(id == "knob.left" ? -1 : 1)) }
        if id == cancelTriggerID { end(); return .init(consumed: true, effect: .cancel) }
        if id == "knob.press", confirmationID == nil { confirmationID = selectedID }
        return .init(consumed: true, effect: nil)
    }
}
