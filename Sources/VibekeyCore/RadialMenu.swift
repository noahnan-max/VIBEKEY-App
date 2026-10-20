import Foundation

public struct RadialMenuItem: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var steps: [WorkflowStep]
    public init(id: UUID = UUID(), name: String, steps: [WorkflowStep]) {
        self.id = id; self.name = name; self.steps = steps
    }
}

/// Array order is the display/execution order. Core performs no file I/O.
public enum RadialActivation: String, Codable, CaseIterable {
    case middleHold, knobPress, topPress, middlePress, bottomPress, topHold, bottomHold, knobHold
    public var triggerID: String {
        switch self {
        case .topPress, .topHold: return "key.0"
        case .middlePress, .middleHold: return "key.1"
        case .bottomPress, .bottomHold: return "key.2"
        case .knobPress, .knobHold: return "knob.press"
        }
    }
    public var requiresHold: Bool { [.topHold, .middleHold, .bottomHold, .knobHold].contains(self) }
    public var cancelTriggerID: String { triggerID == "key.2" ? "key.0" : "key.2" }
    public var triggerTitle: String { ["key.0":"上键", "key.1":"中键", "key.2":"下键", "knob.press":"旋钮" ][triggerID]! }
    public var title: String { triggerTitle + (requiresHold ? "长按" : "单击") }
    public var instruction: String { title + "打开 · 转动选择 · 再按触发键或旋钮确认 · " + (cancelTriggerID == "key.0" ? "上键取消" : "下键取消") }
    public static func selection(triggerID: String, hold: Bool) -> RadialActivation? {
        allCases.first { $0.triggerID == triggerID && $0.requiresHold == hold }
    }
}

public struct RadialMenuDocument: Codable, Equatable {
    public var schemaVersion: Int
    public var enabled: Bool
    public var items: [RadialMenuItem]
    public var activation: RadialActivation
    public init(schemaVersion: Int = 1, enabled: Bool = false, items: [RadialMenuItem] = [], activation: RadialActivation = .middleHold) {
        self.schemaVersion = schemaVersion; self.enabled = enabled; self.items = items; self.activation = activation
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, enabled, items, activation }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        items = try values.decode([RadialMenuItem].self, forKey: .items)
        if schemaVersion == 2 || schemaVersion == 3 { activation = try values.decode(RadialActivation.self, forKey: .activation) }
        else { activation = try values.decodeIfPresent(RadialActivation.self, forKey: .activation) ?? .middleHold }
    }
    public var pageCount: Int { (items.count + RadialMenuValidation.itemsPerPage - 1) / RadialMenuValidation.itemsPerPage }
    public func page(_ index: Int) -> [RadialMenuItem] {
        guard index >= 0, index < pageCount else { return [] }
        let start = index * RadialMenuValidation.itemsPerPage
        return Array(items[start..<min(start + RadialMenuValidation.itemsPerPage, items.count)])
    }
    public func reordered(ids: [UUID]) throws -> RadialMenuDocument {
        try RadialMenuValidation.validate(self)
        guard ids.count == items.count, Set(ids).count == ids.count, Set(ids) == Set(items.map(\.id)) else {
            throw RadialMenuError.invalid("排序必须完整保留每个选项，且不能重复。")
        }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var copy = self; copy.items = ids.map { byID[$0]! }; return copy
    }
}

public enum RadialMenuError: Error, LocalizedError {
    case invalid(String), unsupportedSchema, malformedData, oversizedData
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .unsupportedSchema: return "轮盘文件版本不受支持，原文件应予保留。"
        case .malformedData: return "轮盘文件损坏，不能替换成空配置。"
        case .oversizedData: return "轮盘文件超过 1 MB 上限。"
        }
    }
}

public enum RadialMenuValidation {
    public static let maximumItems = 64
    public static let itemsPerPage = 8
    public static let maximumDataBytes = 1_048_576
    public static func validate(_ document: RadialMenuDocument) throws {
        guard (1...3).contains(document.schemaVersion) else { throw RadialMenuError.unsupportedSchema }
        guard document.schemaVersion != 1 || document.activation == .middleHold,
              document.schemaVersion != 2 || [.middleHold, .knobPress].contains(document.activation) else { throw RadialMenuError.invalid("自定义触发方式需要新版轮盘配置。") }
        guard document.items.count <= maximumItems else { throw RadialMenuError.invalid("轮盘最多支持 64 个选项。") }
        guard !document.enabled || !document.items.isEmpty else { throw RadialMenuError.invalid("启用轮盘前请先添加选项。") }
        var identifiers = Set<UUID>()
        var stringBytes = 0
        let forbidden = CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\u{200C}\u{200D}"))
        for item in document.items {
            guard identifiers.insert(item.id).inserted else { throw RadialMenuError.invalid("轮盘含重复选项标识。") }
            guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.name.count <= 128, item.name.utf16.count <= 512,
                  item.name.rangeOfCharacter(from: forbidden) == nil else { throw RadialMenuError.invalid("轮盘选项名称无效。") }
            guard !item.steps.isEmpty, item.steps.count <= WorkflowValidation.maximumStepCount else {
                throw RadialMenuError.invalid("每个轮盘选项需要 1–64 个工作流步骤。")
            }
            stringBytes += item.name.utf8.count
            for step in item.steps {
                guard step.kind != .passthrough else { throw RadialMenuError.invalid("轮盘选项不能使用沿用设备快捷键动作。") }
                guard step.argument.utf8.count <= 8_192 else { throw RadialMenuError.oversizedData }
                stringBytes += step.argument.utf8.count
                guard stringBytes <= maximumDataBytes else { throw RadialMenuError.oversizedData }
            }
            // Reuse the workflow validator without its optional app-path file
            // lookup. The host resolves a chosen application to its bundle ID.
            for step in item.steps where step.kind == .openApp {
                guard WorkflowValidation.validBundleIdentifier(step.argument) else {
                    throw RadialMenuError.invalid("轮盘应用动作需要应用的 bundle ID。")
                }
            }
            try WorkflowValidation.validate(item.steps)
        }
    }
}

public enum RadialMenuCodec {
    public static func decode(_ data: Data) throws -> RadialMenuDocument {
        guard data.count <= RadialMenuValidation.maximumDataBytes else { throw RadialMenuError.oversizedData }
        let document: RadialMenuDocument
        do { document = try JSONDecoder().decode(RadialMenuDocument.self, from: data) }
        catch { throw RadialMenuError.malformedData }
        try RadialMenuValidation.validate(document)
        return document
    }
    public static func encode(_ document: RadialMenuDocument) throws -> Data {
        try RadialMenuValidation.validate(document)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= RadialMenuValidation.maximumDataBytes else { throw RadialMenuError.oversizedData }
        return data
    }
}

/// Eight fixed sectors, starting at twelve o'clock and proceeding clockwise.
/// Coordinates use the usual screen convention: positive y points downwards.
public enum RadialMenuGeometry {
    public static func centerAngle(slot: Int) -> Double? {
        guard (0..<RadialMenuValidation.itemsPerPage).contains(slot) else { return nil }
        return -Double.pi / 2 + Double(slot) * Double.pi / 4
    }
    public static func hitTest(x: Double, y: Double, innerRadius: Double, outerRadius: Double, itemCount: Int) -> Int? {
        guard x.isFinite, y.isFinite, innerRadius.isFinite, outerRadius.isFinite,
              innerRadius >= 0, outerRadius > innerRadius, (1...8).contains(itemCount) else { return nil }
        let radius = hypot(x, y)
        guard radius.isFinite, radius > innerRadius, radius <= outerRadius else { return nil }
        var angle = (atan2(y, x) + Double.pi / 2 + Double.pi / 8).truncatingRemainder(dividingBy: 2 * Double.pi)
        if angle < 0 { angle += 2 * Double.pi }
        let slot = min(7, Int(floor(angle / (Double.pi / 4))))
        return slot < itemCount ? slot : nil
    }
}
