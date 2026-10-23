import Foundation

public struct AU05SmartSnapshot: Codable, Equatable {
    public var connectionID: UUID
    public var firmware: String
    public var shortcuts: [AU05OnboardShortcut]
    public var lightingPayload: [UInt8]
    public var workflows: [WorkflowBinding]
    public var workflowsEnabled: Bool
    public var agentLightingEnabled: Bool
    public var knobPressReserved: Bool
    public init(connectionID: UUID, firmware: String, shortcuts: [AU05OnboardShortcut], lightingPayload: [UInt8], workflows: [WorkflowBinding], workflowsEnabled: Bool, agentLightingEnabled: Bool, knobPressReserved: Bool) {
        self.connectionID = connectionID; self.firmware = firmware; self.shortcuts = shortcuts; self.lightingPayload = lightingPayload
        self.workflows = workflows; self.workflowsEnabled = workflowsEnabled; self.agentLightingEnabled = agentLightingEnabled; self.knobPressReserved = knobPressReserved
    }
    public var lighting: SmartLightingSnapshot { get throws { try .init(connectionID: connectionID, payload: lightingPayload) } }
    public static func == (a: Self, b: Self) -> Bool {
        a.connectionID == b.connectionID && a.firmware == b.firmware && a.shortcuts == b.shortcuts &&
            (try? a.lighting) == (try? b.lighting) && a.workflows == b.workflows && a.workflowsEnabled == b.workflowsEnabled &&
            a.agentLightingEnabled == b.agentLightingEnabled && a.knobPressReserved == b.knobPressReserved
    }
    public func validate() throws {
        guard !firmware.isEmpty, lightingPayload.count == 24, shortcuts.map(\.index) == Array(UInt8(0)...5), shortcuts.allSatisfy(\.writable) else { throw AU05ShortcutError.unsupported }
        _ = try lighting; try WorkflowValidation.validate(workflows)
    }
    public static let triggers = ["key.0", "key.1", "key.2", "knob.press", "knob.right", "knob.left"]
    public static func title(_ trigger: String) -> String {
        ["key.0":"上键", "key.1":"中键", "key.2":"下键", "knob.press":"旋钮按下", "knob.right":"旋钮右转", "knob.left":"旋钮左转"][trigger] ?? trigger
    }
}

public struct AU05SmartKeyChange: Codable, Equatable {
    public var trigger: String
    public var action: String
    public var keyCode: Int?
    public var modifiers: UInt64?
    public init(trigger: String, action: String = "shortcut", keyCode: Int? = nil, modifiers: UInt64? = nil) {
        self.trigger = trigger; self.action = action; self.keyCode = keyCode; self.modifiers = modifiers
    }
}
public struct AU05SmartStep: Codable, Equatable {
    public var kind: String
    public var keyCode: Int?
    public var modifiers: UInt64?
    public var seconds: Double?
    public var scrollLines: Int?
    public init(kind: String, keyCode: Int? = nil, modifiers: UInt64? = nil, seconds: Double? = nil, scrollLines: Int? = nil) {
        self.kind = kind; self.keyCode = keyCode; self.modifiers = modifiers; self.seconds = seconds; self.scrollLines = scrollLines
    }
}
public struct AU05SmartMacroChange: Codable, Equatable {
    public var trigger: String
    public var name: String
    public var remove: Bool
    public var steps: [AU05SmartStep]
    public init(trigger: String, name: String, remove: Bool = false, steps: [AU05SmartStep] = []) {
        self.trigger = trigger; self.name = name; self.remove = remove; self.steps = steps
    }
}
public struct AU05SmartLightChange: Codable, Equatable {
    public var mode: Int?
    public var brightness: Int?
    public init(mode: Int? = nil, brightness: Int? = nil) { self.mode = mode; self.brightness = brightness }
}
public struct AU05SmartPlan: Codable, Equatable {
    public var summary: String
    public var clarification: String?
    public var keys: [AU05SmartKeyChange]
    public var macros: [AU05SmartMacroChange]
    public var lighting: AU05SmartLightChange?
    public init(summary: String, clarification: String? = nil, keys: [AU05SmartKeyChange] = [], macros: [AU05SmartMacroChange] = [], lighting: AU05SmartLightChange? = nil) {
        self.summary = summary; self.clarification = clarification; self.keys = keys; self.macros = macros; self.lighting = lighting
    }
}
public struct AU05SmartPrepared {
    public let plan: AU05SmartPlan
    public let baseline: AU05SmartSnapshot
    public let desired: AU05SmartSnapshot
    public let changes: [String]
    public let acknowledgements: [String]
    public var hasChanges: Bool { baseline != desired }
}

public enum AU05SmartPlanner {
    private static func reject(_ message: String) -> WorkflowError { .invalidConfiguration(message) }
    public static func shortcut(code: Int?, modifiers: UInt64?) throws -> RecordedShortcut {
        let flags = modifiers ?? 0
        guard let code, (0...127).contains(code), flags & ~UInt64(0x1e0000) == 0 else { throw reject("快捷键包含不支持的键码或修饰键。") }
        let value = RecordedShortcut(keyCode: UInt16(code), modifiers: flags)
        _ = try AU05OnboardShortcut.entries(for: value); return value
    }
    public static func prepare(_ plan: AU05SmartPlan, baseline: AU05SmartSnapshot) throws -> AU05SmartPrepared {
        try baseline.validate()
        guard plan.summary.count <= 2000, (plan.clarification?.count ?? 0) <= 2000, plan.keys.count <= 6, plan.macros.count <= 6 else { throw reject("方案超出单次可审核范围。") }
        if let q = plan.clarification, !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard plan.keys.isEmpty, plan.macros.isEmpty, plan.lighting == nil else { throw reject("模型同时提出问题和改动，已拒绝写入。") }
        }
        var target = baseline, changes: [String] = [], acknowledgements: [String] = [], used = Set<String>()
        // A new macro enables the shared host switch. A previously disabled
        // application-specific binding can then mask another requested change.
        let scopesWillBeActive = baseline.workflowsEnabled || plan.macros.contains { !$0.remove }
        func validateTrigger(_ trigger: String) throws {
            guard AU05SmartSnapshot.triggers.contains(trigger), used.insert(trigger).inserted else { throw reject("按键位置无效、重复或同时配置了设备快捷键与 Mac 宏。") }
            if scopesWillBeActive, baseline.workflows.contains(where: { $0.triggerID == trigger && !$0.applicationBundleID.isEmpty && $0.steps.contains(where: { $0.kind != .passthrough }) }) {
                throw reject("\(AU05SmartSnapshot.title(trigger))已有按应用优先执行的宏，请先在宏与工作流中处理该绑定，再生成方案。")
            }
            if trigger == "knob.press", baseline.knobPressReserved { throw reject("旋钮按下当前用于快捷轮盘，请先更换轮盘激活方式或关闭轮盘，再配置此位置。") }
        }
        func clearGlobal(_ trigger: String) {
            for i in target.workflows.indices where target.workflows[i].triggerID == trigger && target.workflows[i].applicationBundleID.isEmpty {
                if target.workflows[i].steps.contains(where: { $0.kind != .passthrough }) {
                    acknowledgements.append("\(AU05SmartSnapshot.title(trigger))的原 Mac 宏将改为执行设备映射（原内容已备份）")
                    target.workflows[i].steps = [WorkflowStep(kind: .passthrough)]
                }
            }
        }
        for key in plan.keys {
            try validateTrigger(key.trigger)
            let index = Int(AU05OnboardShortcut.index(for: key.trigger)!)
            let entries: [AU05ShortcutEntry]
            switch key.action {
            case "shortcut": entries = try AU05OnboardShortcut.entries(for: shortcut(code: key.keyCode, modifiers: key.modifiers))
            case "none", "scrollUp", "scrollDown":
                guard key.keyCode == nil, key.modifiers == nil else { throw reject("非快捷键动作不能携带键码。") }
                entries = key.action == "none" ? [] : [.init(page: 7, usage: key.action == "scrollUp" ? 5 : 6)]
            default: throw reject("模型提出了未支持的设备动作。")
            }
            let old = target.shortcuts[index]; target.shortcuts[index] = try old.replacing(entries: entries)
            clearGlobal(key.trigger)
            if old != target.shortcuts[index] { changes.append("设备 · \(AU05SmartSnapshot.title(key.trigger))：\(old.label) → \(target.shortcuts[index].label)") }
        }
        for macro in plan.macros {
            try validateTrigger(macro.trigger)
            if macro.remove {
                guard macro.steps.isEmpty else { throw reject("移除宏不能同时写入步骤。") }; clearGlobal(macro.trigger); continue
            }
            guard !macro.steps.isEmpty, macro.steps.count <= 64 else { throw reject("宏需要1–64个步骤。") }
            var delay: Double = 0
            let steps = try macro.steps.map { step -> WorkflowStep in
                guard let kind = ActionKind(rawValue: step.kind), [.shortcut, .delay, .scrollUp, .scrollDown, .volumeUp, .volumeDown, .toggleMute].contains(kind) else { throw reject("智能宏只允许快捷键、延时、滚动及音量动作。") }
                if kind == .shortcut { _ = try shortcut(code: step.keyCode, modifiers: step.modifiers) }
                else if step.keyCode != nil || step.modifiers != nil { throw reject("非快捷键步骤不能携带键码。") }
                if kind == .delay {
                    guard let seconds = step.seconds, seconds.isFinite, (0...30).contains(seconds) else { throw reject("每步延时须为0–30秒。") }; delay += seconds
                } else if step.seconds != nil { throw reject("非延时步骤不能携带延时。") }
                if kind == .scrollUp || kind == .scrollDown {
                    guard let lines = step.scrollLines, (1...50).contains(lines) else { throw reject("滚动须为1–50行。") }
                } else if step.scrollLines != nil { throw reject("非滚动步骤不能携带滚动行数。") }
                return WorkflowStep(kind: kind, keyCode: UInt16(step.keyCode ?? 0), modifiers: step.modifiers ?? 0, seconds: step.seconds ?? 0, scrollLines: step.scrollLines ?? 3)
            }
            guard delay <= 60 else { throw reject("宏的累计延时不能超过60秒。") }
            let existing = target.workflows.firstIndex { $0.triggerID == macro.trigger && $0.applicationBundleID.isEmpty }
            let binding = WorkflowBinding(id: existing.map { target.workflows[$0].id } ?? UUID(), name: macro.name, triggerID: macro.trigger, steps: steps)
            if let existing {
                if target.workflows[existing].steps.contains(where: { $0.kind != .passthrough }) { acknowledgements.append("替换\(AU05SmartSnapshot.title(macro.trigger))的现有 Mac 宏（原内容已备份）") }
                target.workflows[existing] = binding
            } else { target.workflows.append(binding) }
            target.workflowsEnabled = true
            changes.append("全局 Mac 宏 · \(AU05SmartSnapshot.title(macro.trigger))：\(macro.name)，\(steps.count)步；退出 VIBEKEY 后暂停")
        }
        if !baseline.workflowsEnabled && target.workflowsEnabled { acknowledgements.append("启用 Mac 宏开关；已有的其他 Mac 宏也会恢复执行") }
        if let light = plan.lighting {
            guard light.mode != nil || light.brightness != nil else { throw reject("灯光方案为空。") }
            let old = try baseline.lighting
            guard let mode = SmartLightingMode(rawValue: light.mode ?? old.mode.rawValue) else { throw reject("AU05 仅支持全灭、全亮和工作模式，不能设置未知 RGB 灯色。") }
            if light.brightness != nil && mode != .allOn { throw reject("亮度属于全亮模式，请明确使用全亮模式再设置亮度。") }
            let desired = try old.applying(.init(mode: mode, brightness: light.brightness)); target.lightingPayload = desired.rawPayload
            if desired != old {
                changes.append("设备灯光：\(old.mode.title)/\(old.brightness) → \(mode.title)/\(desired.brightness)（亮度0–20）")
                if baseline.agentLightingEnabled { target.agentLightingEnabled = false; acknowledgements.append("停止 Agent 状态灯跟随，以保留这次手动灯光；原开关状态也会备份") }
            }
        }
        try target.validate()
        changes += acknowledgements
        return AU05SmartPrepared(plan: plan, baseline: baseline, desired: target, changes: changes, acknowledgements: acknowledgements)
    }
}

@MainActor public struct AU05SmartAdapter {
    public var read: () async throws -> AU05SmartSnapshot
    public var writeShortcut: (AU05OnboardShortcut) async throws -> Void
    public var writeLighting: (SmartLightingSnapshot, SmartLightingSnapshot) async throws -> Void
    public var writeHost: (AU05SmartSnapshot, AU05SmartSnapshot) throws -> Void
    public init(read: @escaping () async throws -> AU05SmartSnapshot, writeShortcut: @escaping (AU05OnboardShortcut) async throws -> Void, writeLighting: @escaping (SmartLightingSnapshot, SmartLightingSnapshot) async throws -> Void, writeHost: @escaping (AU05SmartSnapshot, AU05SmartSnapshot) throws -> Void) {
        self.read = read; self.writeShortcut = writeShortcut; self.writeLighting = writeLighting; self.writeHost = writeHost
    }
}

/// One complete, compare-before-write AU05 transaction. The application owns
/// the sole DeviceSession reservation and durable journal across this call.
@MainActor public final class AU05SmartTransaction {
    public private(set) var isBusy = false
    public init() {}
    public func commit(expected: AU05SmartSnapshot, desired: AU05SmartSnapshot, adapter: AU05SmartAdapter,
                       backup: (AU05SmartSnapshot) throws -> Void) async throws -> AU05SmartSnapshot {
        guard !isBusy else { throw AU05ShortcutError.busy }
        try expected.validate(); try desired.validate()
        guard expected.connectionID == desired.connectionID, expected.firmware == desired.firmware,
              expected.knobPressReserved == desired.knobPressReserved,
              try expected.lighting.workRecords == desired.lighting.workRecords else { throw AU05ShortcutError.unsupported }
        isBusy = true; defer { isBusy = false }
        guard try await adapter.read() == expected else { throw AU05ShortcutError.changed }
        try backup(expected)
        guard try await adapter.read() == expected else { throw AU05ShortcutError.changed }
        var current = expected, attemptedKeys = Set<Int>(), attemptedLights = false, attemptedHost = false
        do {
            for i in 0..<6 where expected.shortcuts[i] != desired.shortcuts[i] {
                guard try await adapter.read() == current else { throw AU05ShortcutError.changed }
                attemptedKeys.insert(i); try await adapter.writeShortcut(desired.shortcuts[i]); current.shortcuts[i] = desired.shortcuts[i]
                guard try await adapter.read() == current else { throw AU05ShortcutError.invalidReply }
            }
            if try current.lighting != desired.lighting {
                guard try await adapter.read() == current else { throw AU05ShortcutError.changed }
                attemptedLights = true; try await adapter.writeLighting(current.lighting, desired.lighting)
                current.lightingPayload = desired.lightingPayload
            }
            if current.workflows != desired.workflows || current.workflowsEnabled != desired.workflowsEnabled || current.agentLightingEnabled != desired.agentLightingEnabled {
                guard try await adapter.read() == current else { throw AU05ShortcutError.changed }
                attemptedHost = true; try adapter.writeHost(current, desired)
            }
            let final = try await adapter.read()
            guard final == desired else { throw AU05ShortcutError.invalidReply }; return final
        } catch {
            guard !attemptedKeys.isEmpty || attemptedLights || attemptedHost else { throw error }
            do {
                let observed = try await adapter.read()
                var restoring = observed
                guard observed.connectionID == expected.connectionID, observed.firmware == expected.firmware,
                      observed.knobPressReserved == expected.knobPressReserved,
                      observed.workflows == expected.workflows || observed.workflows == desired.workflows,
                      [expected.workflowsEnabled, desired.workflowsEnabled].contains(observed.workflowsEnabled),
                      [expected.agentLightingEnabled, desired.agentLightingEnabled].contains(observed.agentLightingEnabled),
                      try observed.lighting.workRecords == expected.lighting.workRecords else { throw AU05ShortcutError.recoveryRequired }
                for i in 0..<6 { guard observed.shortcuts[i] == expected.shortcuts[i] || (attemptedKeys.contains(i) && observed.shortcuts[i] == desired.shortcuts[i]) else { throw AU05ShortcutError.recoveryRequired } }
                if attemptedLights {
                    // Restore even after a failed/late read; acknowledgement is not state.
                    let original = try expected.lighting, now = try observed.lighting
                    guard [original.mode, try desired.lighting.mode].contains(now.mode), [original.brightness, try desired.lighting.brightness].contains(now.brightness) else { throw AU05ShortcutError.recoveryRequired }
                    try await adapter.writeLighting(now, original)
                    restoring.lightingPayload = expected.lightingPayload
                } else { guard try observed.lighting == expected.lighting else { throw AU05ShortcutError.recoveryRequired } }
                for i in attemptedKeys.sorted() {
                    guard try await adapter.read() == restoring else { throw AU05ShortcutError.recoveryRequired }
                    try await adapter.writeShortcut(expected.shortcuts[i]); restoring.shortcuts[i] = expected.shortcuts[i]
                }
                if attemptedHost {
                    guard try await adapter.read() == restoring else { throw AU05ShortcutError.recoveryRequired }
                    try adapter.writeHost(restoring, expected)
                }
                guard try await adapter.read() == expected else { throw AU05ShortcutError.recoveryRequired }
            } catch { throw AU05ShortcutError.recoveryRequired }
            throw AU05ShortcutError.restored
        }
    }
}
