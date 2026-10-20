import Foundation

public enum AU05ShortcutError: Error, LocalizedError {
    case invalidReply, unsupported, busy, changed, disconnected, storage, restored, recoveryRequired
    public var errorDescription: String? {
        switch self {
        case .invalidReply: return "设备快捷键回复无效或与请求位置不符，请重新读取。"
        case .unsupported: return "这个动作暂不能保存到 AU05，请选择设备支持的快捷键。"
        case .busy: return "设备正在处理配置，请完成后再操作。"
        case .changed: return "设备配置已发生变化，请重新读取后再保存。"
        case .disconnected: return "设备连接已改变，本次配置操作已停止。"
        case .storage: return "无法安全保存设备配置备份，未继续写入。"
        case .restored: return "本次保存未成功，已恢复并读回原配置。"
        case .recoveryRequired: return "设备配置尚未确认恢复，请连接原设备并恢复备份。"
        }
    }
}

/// `page` is a vendor category, not a USB HID usage page: 2=keyboard,
/// 3=modifier bit mask, 7=mouse action. Verified against Studio and live AU05.
public struct AU05ShortcutEntry: Codable, Equatable {
    public let page: UInt8
    public let usage: UInt8
    public let negative: Bool
    public init(page: UInt8, usage: UInt8, negative: Bool = false) {
        self.page = page; self.usage = usage; self.negative = negative
    }
}

public struct AU05OnboardShortcut: Codable, Equatable {
    public static let command = DeviceCommand(6, 0x50, "设备快捷键")
    public let index: UInt8
    public let enabled: UInt8
    public let eventType: UInt8
    public let entries: [AU05ShortcutEntry]
    public init(index: UInt8, entries: [AU05ShortcutEntry], enabled: UInt8 = 1, eventType: UInt8 = 0) throws {
        guard index < 6, entries.count <= 4, entries.allSatisfy({ $0.page < 128 }) else { throw AU05ShortcutError.invalidReply }
        self.index = index; self.entries = entries; self.enabled = enabled; self.eventType = eventType
    }
    public init(reply: DeviceReply, index: UInt8) throws {
        let p = reply.payload
        guard reply.matches(Self.command), reply.isRead, p.count >= 12, p[0] == index, p[2] <= 4 else { throw AU05ShortcutError.invalidReply }
        try self.init(index: index, entries: (0..<Int(p[2])).map {
            AU05ShortcutEntry(page: p[3 + 2 * $0] & 0x7f, usage: p[4 + 2 * $0], negative: p[3 + 2 * $0] & 0x80 != 0)
        }, enabled: p[1], eventType: p[11])
    }
    public var writable: Bool { index < 6 && enabled == 1 && eventType == 0 && entries.count <= 4 && entries.allSatisfy { $0.page < 128 } }
    public func replacing(entries: [AU05ShortcutEntry]) throws -> Self {
        guard writable else { throw AU05ShortcutError.unsupported }
        return try Self(index: index, entries: entries)
    }
    public func writeFrame() throws -> Data {
        guard writable else { throw AU05ShortcutError.unsupported }
        var p: [UInt8] = [index, enabled, UInt8(entries.count)]
        for entry in entries { p += [entry.page | (entry.negative ? 0x80 : 0), entry.usage] }
        p += Array(repeating: 0, count: 11 - p.count); p.append(eventType)
        return Data([1, 6, 0x50, 4] + p + Array(repeating: 0, count: 48))
    }
    public var recordedShortcut: RecordedShortcut? {
        guard enabled == 1, eventType == 0, !entries.isEmpty, entries.allSatisfy({ !$0.negative && ($0.page == 2 || $0.page == 3) }) else { return nil }
        let keyboard = entries.filter { $0.page == 2 }
        let mask = entries.filter { $0.page == 3 }.reduce(UInt8(0)) { $0 | $1.usage }
        if keyboard.count == 1, let code = AU05ShortcutKeyMap.macCode(for: keyboard[0].usage) {
            return RecordedShortcut(keyCode: code, modifiers: AU05ShortcutKeyMap.flags(mask))
        }
        if keyboard.isEmpty, let modifier = AU05ShortcutKeyMap.modifiers.last(where: { mask & $0.bit != 0 }) {
            return RecordedShortcut(keyCode: modifier.code, modifiers: AU05ShortcutKeyMap.flags(mask & ~modifier.bit))
        }
        return nil
    }
    public var scrollDirection: Int? {
        guard enabled == 1, eventType == 0, entries.count == 1, entries[0].page == 7, !entries[0].negative else { return nil }
        return entries[0].usage == 5 ? 1 : (entries[0].usage == 6 ? -1 : nil)
    }
    public var label: String {
        if entries.isEmpty { return "不执行动作" }
        if let direction = scrollDirection { return direction > 0 ? "向上滚动" : "向下滚动" }
        if let shortcut = recordedShortcut { return shortcut.label }
        return "设备已有组合动作"
    }
    public static func entries(for shortcut: RecordedShortcut) throws -> [AU05ShortcutEntry] {
        guard shortcut.modifiers & 0x00800000 == 0, shortcut.keyCode != 63 else { throw AU05ShortcutError.unsupported }
        let own = AU05ShortcutKeyMap.modifiers.first { $0.code == shortcut.keyCode }
        var flags = shortcut.modifiers
        if let own { flags &= ~own.flag }
        var mask = own?.bit ?? 0
        for (flag, bit): (UInt64, UInt8) in [(0x40000, 1), (0x20000, 2), (0x80000, 4), (0x100000, 8)] where flags & flag != 0 { mask |= bit }
        // Mirror Studio's individual modifier entries. Do not assume firmware
        // accepts a newly invented combined-mask encoding for one entry.
        var result = AU05ShortcutKeyMap.modifiers.filter { mask & $0.bit != 0 }.map { AU05ShortcutEntry(page: 3, usage: $0.bit) }
        if own == nil {
            guard let usage = AU05ShortcutKeyMap.hidUsage(for: shortcut.keyCode) else { throw AU05ShortcutError.unsupported }
            result.append(AU05ShortcutEntry(page: 2, usage: usage))
        }
        guard !result.isEmpty, result.count <= 4 else { throw AU05ShortcutError.unsupported }; return result
    }
    public static func index(for trigger: String) -> UInt8? {
        switch trigger { case "key.0": return 0; case "key.1": return 1; case "key.2": return 2; case "knob.press": return 3; case "knob.right": return 4; case "knob.left": return 5; default: return nil }
    }
}

public enum AU05ShortcutKeyMap {
    // macOS virtual key codes -> keyboard usage IDs, matching Studio initMaps.
    private static let pairs: [(UInt16, UInt8)] = [
        (0,4),(11,5),(8,6),(2,7),(14,8),(3,9),(5,10),(4,11),(34,12),(38,13),(40,14),(37,15),(46,16),
        (45,17),(31,18),(35,19),(12,20),(15,21),(1,22),(17,23),(32,24),(9,25),(13,26),(7,27),(16,28),(6,29),
        (18,30),(19,31),(20,32),(21,33),(23,34),(22,35),(26,36),(28,37),(25,38),(29,39),
        (36,40),(53,41),(51,42),(48,43),(49,44),(27,45),(24,46),(33,47),(30,48),(42,49),(50,53),(41,51),(39,52),(43,54),(47,55),(44,56),(57,57),
        (122,58),(120,59),(99,60),(118,61),(96,62),(97,63),(98,64),(100,65),(101,66),(109,67),(103,68),(111,69),
        (105,104),(107,105),(113,106),(106,107),(64,108),(79,109),(80,110),(90,111),
        (114,73),(115,74),(116,75),(117,76),(119,77),(121,78),(124,79),(123,80),(125,81),(126,82),
        (71,83),(75,84),(67,85),(78,86),(69,87),(76,88),(83,89),(84,90),(85,91),(86,92),(87,93),(88,94),(89,95),(91,96),(92,97),(82,98),(65,99),(81,103)
    ]
    public static let modifiers: [(code: UInt16, bit: UInt8, flag: UInt64, side: UInt64)] = [
        (59,1,0x40000,0x1),(56,2,0x20000,0x2),(58,4,0x80000,0x20),(55,8,0x100000,0x8),
        (62,16,0x40000,0x2000),(60,32,0x20000,0x4),(61,64,0x80000,0x40),(54,128,0x100000,0x10)
    ]
    public static func hidUsage(for code: UInt16) -> UInt8? { pairs.first { $0.0 == code }?.1 }
    public static func macCode(for usage: UInt8) -> UInt16? { pairs.first { $0.1 == usage }?.0 }
    public static func flags(_ mask: UInt8, includeSides: Bool = false) -> UInt64 {
        modifiers.filter { mask & $0.bit != 0 }.reduce(0) { $0 | $1.flag | (includeSides ? $1.side : 0) }
    }
}

/// A bridge while the settings app owns the vendor session. The saved device
/// configuration is authoritative; the legacy six defaults are never substituted.
public struct AU05OnboardActionRouter {
    private var held: [String: [UInt16]] = [:]
    private var counts: [UInt16: Int] = [:]
    public init() {}
    private var flags: UInt64 {
        AU05ShortcutKeyMap.modifiers.filter { counts[$0.code, default: 0] > 0 }.reduce(0) { $0 | $1.flag | $1.side }
    }
    public mutating func handle(_ id: String, pressed: Bool, configuration: AU05OnboardShortcut?) -> [OriginalDeviceActionEvent] {
        if !pressed { return release(id) }
        guard held[id] == nil, let configuration, configuration.enabled == 1, configuration.eventType == 0 else { return [] }
        if let direction = configuration.scrollDirection { return [.scroll(lines: Int32(direction), modifiers: flags)] }
        guard configuration.entries.allSatisfy({ !$0.negative && ($0.page == 2 || $0.page == 3) }) else { return [] }
        let mask = configuration.entries.filter { $0.page == 3 }.reduce(UInt8(0)) { $0 | $1.usage }
        let keyboard = configuration.entries.filter { $0.page == 2 }.compactMap { AU05ShortcutKeyMap.macCode(for: $0.usage) }
        guard keyboard.count == configuration.entries.filter({ $0.page == 2 }).count else { return [] }
        let keys = AU05ShortcutKeyMap.modifiers.filter { mask & $0.bit != 0 }.map(\.code) + keyboard
        held[id] = keys; var events: [OriginalDeviceActionEvent] = []
        for code in keys {
            counts[code, default: 0] += 1
            if counts[code] == 1 { events.append(.key(keyCode: code, pressed: true, modifiers: flags)) }
        }
        if configuration.index >= 4 { events += release(id) }
        return events
    }
    private mutating func release(_ id: String) -> [OriginalDeviceActionEvent] {
        guard let keys = held.removeValue(forKey: id) else { return [] }
        var events: [OriginalDeviceActionEvent] = []
        for code in keys.reversed() {
            counts[code, default: 0] -= 1
            if counts[code] == 0 { counts.removeValue(forKey: code); events.append(.key(keyCode: code, pressed: false, modifiers: flags)) }
        }
        return events
    }
    public mutating func releaseAll() -> [OriginalDeviceActionEvent] {
        held.keys.sorted().flatMap { release($0) }
    }
}
