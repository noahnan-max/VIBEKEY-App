import Foundation

public enum DeviceControls {
    private static func frame(_ command: DeviceCommand, flag: UInt8 = 4, payload: [UInt8]) -> Data {
        var data = Data([1, command.group, command.code, flag])
        data.append(contentsOf: payload)
        data.append(Data(repeating: 0, count: 64 - data.count))
        return data
    }
    public static func noiseReduction(level: Int, low: Int, high: Int) throws -> Data {
        guard (0...1).contains(level), (-32768...32767).contains(low), (-32768...32767).contains(high) else { throw ControlError.range }
        let lo = UInt16(bitPattern: Int16(low)), hi = UInt16(bitPattern: Int16(high))
        return frame(.noiseReduction, payload: [UInt8(level), UInt8(truncatingIfNeeded: lo), UInt8(truncatingIfNeeded: lo >> 8), UInt8(truncatingIfNeeded: hi), UInt8(truncatingIfNeeded: hi >> 8)])
    }
    public static func hooks(enabled: Bool) -> Data { frame(.hooks, payload: [enabled ? 1 : 0]) }
    public static func microphone(enabled: Bool) -> Data { frame(.microphone, flag: 0, payload: [enabled ? 1 : 0]) }
    public static func haptics(enabled: Bool) -> Data { frame(.motor, payload: [enabled ? 255 : 0, 0]) }
    public static func sleep(seconds: Int) throws -> Data {
        guard [0, 3600, 7200, 10800, 14400].contains(seconds) else { throw ControlError.range }
        return frame(.sleep, flag: 2, payload: (0..<4).map { UInt8(truncatingIfNeeded: seconds >> (8 * $0)) })
    }
    public static func lightMode(_ mode: Int) throws -> Data {
        guard (0...2).contains(mode) else { throw ControlError.range }
        return frame(.lights, payload: [1, 0, UInt8(mode)])
    }
    public static func lightBrightness(_ brightness: Int) throws -> Data {
        guard (0...20).contains(brightness) else { throw ControlError.range }
        return frame(.lights, payload: [2, 0, 0, UInt8(brightness)])
    }
}

public enum ControlError: Error, LocalizedError {
    case range, mismatch, unavailable
    public var errorDescription: String? {
        switch self { case .range: return "设置值超出支持范围"; case .mismatch: return "设备读回与目标设置不同，未确认成功"; case .unavailable: return "尚未读到当前设置，暂不能修改" }
    }
}
