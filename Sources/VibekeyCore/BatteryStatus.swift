import Foundation

/// AU05's battery reply. The voltage unit and reserved bytes are deliberately
/// retained as wire values; the SDK does not establish a physical unit.
public struct BatteryReading: Equatable {
    public let voltageRaw: Int
    public let percentRaw: Int
    public let chargingRaw: UInt8?
    public let flagsRaw: UInt8?
    public let payload: [UInt8]
    public let readAt: Date

    public init?(reply: DeviceReply, readAt: Date) {
        guard reply.isRead, reply.matches(.battery),
              let voltage = reply.uint16(0), let percent = reply.uint16(2) else { return nil }
        voltageRaw = voltage; percentRaw = percent; payload = reply.payload; self.readAt = readAt
        chargingRaw = payload.count > 6 ? payload[6] : nil
        flagsRaw = payload.count > 7 ? payload[7] : nil
    }
    public var percent: Int? { (0...100).contains(percentRaw) ? percentRaw : nil }
    public var isCharging: Bool? {
        switch chargingRaw { case 0: return false; case 1: return true; default: return nil }
    }
    public var isFull: Bool? { flagsRaw.map { $0 & 0x08 != 0 } }
    public var firmwareLow: Bool? { flagsRaw.map { $0 & 0x04 != 0 } }
    public var powerOffRaw: UInt8? { flagsRaw.map { $0 & 0x03 } }
    public func isFresh(at now: Date, maximumAge: TimeInterval = 90) -> Bool {
        let age = now.timeIntervalSince(readAt)
        return age >= 0 && age <= maximumAge
    }
}

public enum BatteryAlertLevel: Int, Comparable, Equatable {
    case low = 1, critical = 2
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct BatteryWarning: Equatable {
    public let level: BatteryAlertLevel
    public let percent: Int
    public let firmwareLow: Bool
    public var message: String {
        if level == .critical { return "VIBEKEY 电量仅剩 \(percent)%，请及时连接充电。" }
        if firmwareLow && percent > BatteryAlertPolicy.lowThreshold {
            return "VIBEKEY 已报告低电量（当前 \(percent)%），请连接充电。"
        }
        return "VIBEKEY 电量剩余 \(percent)%，建议连接充电。"
    }
}

public struct BatteryAlert: Equatable {
    public let warning: BatteryWarning
    public let readAt: Date
}

/// App thresholds are independent of the firmware's undocumented low threshold.
/// Unknown/stale readings neither alert nor reset an existing discharge cycle.
public struct BatteryAlertPolicy {
    public static let lowThreshold = 20
    public static let criticalThreshold = 10
    public static let recoveryThreshold = 25
    public static let maximumReadingAge: TimeInterval = 90
    private var highestAlerted: BatteryAlertLevel?
    public init() {}

    public static func warning(for reading: BatteryReading?, at now: Date, isCurrent: Bool) -> BatteryWarning? {
        guard isCurrent, let reading, reading.isFresh(at: now, maximumAge: maximumReadingAge),
              let percent = reading.percent, reading.isCharging == false,
              reading.isFull == false, let firmwareLow = reading.firmwareLow,
              firmwareLow || percent <= lowThreshold else { return nil }
        return BatteryWarning(level: percent <= criticalThreshold ? .critical : .low,
                              percent: percent, firmwareLow: firmwareLow)
    }

    public mutating func evaluate(_ reading: BatteryReading?, at now: Date, isCurrent: Bool) -> BatteryAlert? {
        guard isCurrent, let reading, reading.isFresh(at: now, maximumAge: Self.maximumReadingAge),
              let percent = reading.percent else { return nil }
        if reading.isCharging == true || reading.isFull == true {
            highestAlerted = nil; return nil
        }
        guard reading.isCharging == false, reading.isFull == false,
              let firmwareLow = reading.firmwareLow else { return nil }
        if percent >= Self.recoveryThreshold && !firmwareLow { highestAlerted = nil }
        guard let warning = Self.warning(for: reading, at: now, isCurrent: isCurrent),
              highestAlerted.map({ warning.level > $0 }) ?? true else { return nil }
        highestAlerted = warning.level
        return BatteryAlert(warning: warning, readAt: reading.readAt)
    }
}
