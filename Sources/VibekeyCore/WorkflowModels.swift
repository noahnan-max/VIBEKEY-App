import Foundation

public enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case passthrough, shortcut, openApp, openURL, runShortcut, delay, volumeUp, volumeDown, toggleMute, inputSource, scrollUp, scrollDown

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .passthrough: return "VIBEKEY 基础映射"
        case .scrollUp: return "向上滚动"
        case .scrollDown: return "向下滚动"
        case .shortcut: return "快捷键"
        case .openApp: return "打开应用"
        case .openURL: return "打开网址"
        case .runShortcut: return "运行系统快捷指令"
        case .delay: return "等待"
        case .volumeUp: return "调高电脑音量"
        case .volumeDown: return "调低电脑音量"
        case .toggleMute: return "切换电脑静音"
        case .inputSource: return "切换本地输入法"
        }
    }
}

public struct WorkflowStep: Identifiable, Codable, Equatable {
    public var id: UUID
    public var kind: ActionKind
    public var argument: String
    public var keyCode: UInt16
    public var modifiers: UInt64
    public var seconds: Double
    public var scrollLines: Int

    public init(id: UUID = UUID(), kind: ActionKind = .shortcut, argument: String = "",
                keyCode: UInt16 = 0, modifiers: UInt64 = 0, seconds: Double = 0.25, scrollLines: Int = 3) {
        self.id = id
        self.kind = kind
        self.argument = argument
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.seconds = seconds
        self.scrollLines = scrollLines
    }

    private enum CodingKeys: String, CodingKey { case id, kind, argument, keyCode, modifiers, seconds, scrollLines }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); kind = try c.decode(ActionKind.self, forKey: .kind)
        argument = try c.decode(String.self, forKey: .argument); keyCode = try c.decode(UInt16.self, forKey: .keyCode)
        modifiers = try c.decode(UInt64.self, forKey: .modifiers); seconds = try c.decode(Double.self, forKey: .seconds)
        scrollLines = try c.decodeIfPresent(Int.self, forKey: .scrollLines) ?? AU05ActionDefaults.scrollLines
    }

    public var validationError: String? { WorkflowValidation.stepError(self) }
}

public struct WorkflowBinding: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var triggerID: String
    /// An empty value means the binding is available in every application.
    public var applicationBundleID: String
    public var steps: [WorkflowStep]

    public init(id: UUID = UUID(), name: String = "新工作流", triggerID: String = "",
                applicationBundleID: String = "", steps: [WorkflowStep] = []) {
        self.id = id
        self.name = name
        self.triggerID = triggerID
        self.applicationBundleID = applicationBundleID
        self.steps = steps
    }

    public var validationError: String? { WorkflowValidation.bindingError(self) }
}

public enum WorkflowError: LocalizedError {
    case invalidConfiguration(String)
    case accessibilityRequired
    case alreadyRunning
    case timedOut(String)
    case systemFailure(String)
    case audioUnavailable(String)
    case commandFailed(Int32, Bool)
    case damagedConfiguration
    case unsupportedConfigurationVersion

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): return message
        case .accessibilityRequired: return "快捷键需要 Vibekey 的辅助功能权限，请在系统设置中由你授权。"
        case .alreadyRunning: return "上一个工作流仍在执行，本次触发已跳过。"
        case .timedOut(let action): return "\(action)超时，已停止后续步骤。"
        case .systemFailure(let message), .audioUnavailable(let message): return message
        case .commandFailed(let code, let hasErrorOutput):
            return "快捷指令未成功（退出码 \(code)）" + (hasErrorOutput ? "；子进程错误输出已隐藏。" : "。")
        case .damagedConfiguration: return "工作流文件已损坏或含无效配置；已保留原文件，请先备份并修复。"
        case .unsupportedConfigurationVersion: return "工作流文件来自其他版本；已保留原文件。"
        }
    }
}

public enum WorkflowValidation {
    public static let maximumStepCount = 64
    public static let maximumBindingCount = 256
    public static let maximumDuration: Double = 120
    public static let shortcutTimeout: Double = 20
    public static let workspaceTimeout: Double = 10
    /// CGEvent flags for Shift, Control, Option, Command and Function only.
    public static let allowedModifierMask: UInt64 = 0x00800000 | 0x00100000 | 0x00080000 | 0x00040000 | 0x00020000

    public static func validate(_ steps: [WorkflowStep]) throws {
        guard !steps.isEmpty else { throw WorkflowError.invalidConfiguration("工作流至少需要一个步骤。") }
        guard steps.count <= maximumStepCount else {
            throw WorkflowError.invalidConfiguration("每个工作流最多支持 \(maximumStepCount) 个步骤。")
        }
        var identifiers = Set<UUID>()
        var budget: Double = 0
        for (index, step) in steps.enumerated() {
            guard identifiers.insert(step.id).inserted else {
                throw WorkflowError.invalidConfiguration("工作流含重复的步骤标识。")
            }
            if let error = stepError(step) {
                throw WorkflowError.invalidConfiguration("第 \(index + 1) 步：\(error)")
            }
            budget += durationBudget(for: step)
        }
        guard budget <= maximumDuration else {
            throw WorkflowError.invalidConfiguration("步骤的最长执行预算超过 \(Int(maximumDuration)) 秒，请拆分工作流。")
        }
    }

    public static func validate(_ bindings: [WorkflowBinding]) throws {
        guard bindings.count <= maximumBindingCount else {
            throw WorkflowError.invalidConfiguration("工作流数量超过上限。")
        }
        var identifiers = Set<UUID>()
        var contexts = Set<String>()
        for binding in bindings {
            guard identifiers.insert(binding.id).inserted else {
                throw WorkflowError.invalidConfiguration("配置含重复的工作流标识。")
            }
            if let error = bindingError(binding) { throw WorkflowError.invalidConfiguration(error) }
            let context = binding.triggerID + "\u{0}" + binding.applicationBundleID.lowercased()
            guard contexts.insert(context).inserted else {
                throw WorkflowError.invalidConfiguration("同一按键在同一应用场景中只能绑定一个工作流。")
            }
        }
    }

    public static func stepError(_ step: WorkflowStep) -> String? {
        guard step.seconds.isFinite else { return "步骤包含不能保存的非有限数值。" }
        guard AU05ActionDefaults.scrollRange.contains(step.scrollLines) else { return "每格滚动需为1–50行。" }
        switch step.kind {
        case .passthrough: break
        case .shortcut:
            guard step.keyCode <= 127 else { return "键码必须处于 macOS 键盘的 0–127 范围。" }
            guard step.modifiers & ~allowedModifierMask == 0 else { return "快捷键包含不支持的修饰键位。" }
        case .openApp:
            if !validApplicationArgument(step.argument) { return "填写应用的 bundle ID，或真实存在的绝对 .app 路径。" }
        case .openURL:
            if webURL(step.argument) == nil { return "网址必须是有主机名、不含账号密码的 http 或 https 地址。" }
        case .runShortcut:
            if !validShortcutName(step.argument) { return "快捷指令名称不能为空、以减号开头或包含控制字符。" }
        case .delay:
            if !step.seconds.isFinite || !(0...30).contains(step.seconds) { return "等待时间必须是 0–30 秒的有限数值。" }
        case .volumeUp, .volumeDown, .toggleMute, .scrollUp, .scrollDown: break
        case .inputSource:
            if trimmed(step.argument).isEmpty || step.argument.utf8.count>256 || containsControlCharacters(step.argument) {return "请选择已启用的本地输入法。"}
        }
        return nil
    }

    public static func bindingError(_ binding: WorkflowBinding) -> String? {
        let name = trimmed(binding.name)
        guard !name.isEmpty, name.count <= 128, !containsControlCharacters(binding.name) else { return "工作流名称无效。" }
        guard !binding.triggerID.isEmpty, binding.triggerID.count <= 64,
              binding.triggerID == trimmed(binding.triggerID), !containsControlCharacters(binding.triggerID) else {
            return "工作流需要一个有效按键标识。"
        }
        guard binding.applicationBundleID.isEmpty || validBundleIdentifier(binding.applicationBundleID) else {
            return "应用场景必须使用完整的 bundle ID，留空表示全局。"
        }
        do { try validate(binding.steps) } catch { return error.localizedDescription }
        return nil
    }

    public static func shortcutArguments(for name: String) throws -> [String] {
        guard validShortcutName(name) else { throw WorkflowError.invalidConfiguration("快捷指令名称无效。") }
        // The entire name is one argv value, including quotes or shell metacharacters.
        return ["run", trimmed(name)]
    }

    public static func webURL(_ text: String) -> URL? {
        guard text.count <= 2048, !containsControlCharacters(text),
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = components.host, !host.isEmpty,
              !containsControlCharacters(host),
              !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        if let port = components.port, !(1...65535).contains(port) { return nil }
        return url
    }

    public static func validBundleIdentifier(_ text: String) -> Bool {
        guard text.count <= 255 else { return false }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy { allowed.contains($0) } }
    }

    static func durationBudget(for step: WorkflowStep) -> Double {
        switch step.kind {
        case .passthrough: return 0
        case .delay: return step.seconds
        case .runShortcut: return shortcutTimeout
        case .openApp, .openURL: return workspaceTimeout
        case .shortcut, .scrollUp, .scrollDown: return 0.05
        case .volumeUp, .volumeDown, .toggleMute: return 1
        case .inputSource: return 2
        }
    }

    static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func containsControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }

    private static func validShortcutName(_ text: String) -> Bool {
        let name = trimmed(text)
        return !name.isEmpty && name.count <= 256 && !name.hasPrefix("-") && !containsControlCharacters(text)
    }

    private static func validApplicationArgument(_ text: String) -> Bool {
        guard text.count <= 1024, text == trimmed(text), !containsControlCharacters(text) else { return false }
        if validBundleIdentifier(text) { return true }
        guard text.hasPrefix("/"), URL(fileURLWithPath: text).pathExtension.lowercased() == "app" else { return false }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: text, isDirectory: &directory), directory.boolValue,
              let bundle = Bundle(url: URL(fileURLWithPath: text)), let executable = bundle.executableURL else { return false }
        return FileManager.default.isExecutableFile(atPath: executable.path)
    }
}
