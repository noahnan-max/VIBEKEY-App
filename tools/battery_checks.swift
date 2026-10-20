import Foundation
@testable import VibekeyCore

private enum BatteryFixtureError: Error { case invalidFrame, deadline }
private func batteryReply(percent: Int, charging: UInt8 = 0, flags: UInt8 = 0, at: Date) -> BatteryReading {
    let bytes: [UInt8] = [0x81, 1, 2, 0x11, 0x77, 0x0f, UInt8(truncatingIfNeeded: percent), UInt8(truncatingIfNeeded: percent >> 8), 0xaa, 0xbb, charging, flags]
    return BatteryReading(reply: DeviceReply(decoded: Data(bytes))!, readAt: at)!
}
private final class BatteryMemoryTransport: DeviceTransporting {
    var onReport: ((Data) -> Void)?
    var onConnection: ((Bool, String) -> Void)?
    var sent: [Data] = []
    var battery: [UInt8] = [0x77, 0x0f, 90, 0, 0xaa, 0xbb, 0, 0]
    var lights: [UInt8] = [255, 3, 0, 5] + Array(20...39)
    var intercept: ((Data) -> Bool)?
    private var generation = 0
    private var connected = false
    var batteryReads: [Data] { sent.filter { $0[0] & 31 == 1 && $0[1] == 1 && $0[2] == 2 && $0[3] & 1 == 1 } }
    var settingWrites: [Data] { sent.filter { $0[0] & 31 == 1 && $0[3] & 1 == 0 } }
    func start() { connected = true; generation += 1; onConnection?(true, "battery memory fixture") }
    func stop() { guard connected else { return }; connected = false; generation += 1; onConnection?(false, "battery fixture stopped") }
    func send(report: Data) throws -> Int32 {
        guard let frame = AU05Codec.decodeReport(report) else { throw BatteryFixtureError.invalidFrame }
        sent.append(frame)
        if intercept?(frame) == true { return 0 }
        if frame[0] & 31 == 1 || (frame[0] & 31 == 6 && frame[1] == 3 && frame[2] == 10) {
            let token = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { [weak self] in
                guard let self, connected, generation == token else { return }
                try? respond(frame)
            }
        }
        return 0
    }
    func deliver(_ bytes: [UInt8]) throws {
        guard bytes.count <= 64 else { throw BatteryFixtureError.invalidFrame }
        onReport?(try AU05Codec.outputReport(plaintext: Data(bytes) + Data(repeating: 0, count: 64 - bytes.count)))
    }
    func respond(_ frame: Data) throws {
        let payload: [UInt8]
        switch (frame[0] & 31, frame[1], frame[2]) {
        case (6, 3, 10): payload = [1]
        case (1, 1, 2): payload = battery
        case (1, 11, 136): payload = lights
        case (1, 4, 4): payload = Array(repeating: 0, count: 15)
        case (1, 1, 144): payload = [0, 0, 0, 0, 0]
        default: payload = [0, 0, 0, 0]
        }
        try deliver([128 | (frame[0] & 31), frame[1], frame[2], frame[3] & 1 == 1 ? 17 : 16] + payload)
    }
    func authorize() throws {
        guard let request = sent.last(where: { $0[0] & 31 == 6 && $0[1] == 2 && $0[2] == 5 }) else { throw BatteryFixtureError.invalidFrame }
        let challenge = (0..<4).reduce(UInt32(0)) { $0 | UInt32(request[5 + $1]) << ($1 * 8) }
        let encoded = challenge ^ 0xd9f4e04c
        try deliver([134, 2, 5, 17, 5] + (0..<4).map { UInt8(truncatingIfNeeded: encoded >> ($0 * 8)) })
    }
}
private final class BatteryClock { var now = Date(timeIntervalSince1970: 1_800_000_000) }
@MainActor private func pump(_ seconds: TimeInterval = 0.01) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
@MainActor @discardableResult private func until(timeout: TimeInterval = 3, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline { pump(0.005) }
    return predicate()
}
@MainActor private struct BatteryHarness {
    let transport = BatteryMemoryTransport()
    let clock = BatteryClock()
    let session: DeviceSession
    let store: DeviceStore
    init(percent: UInt8 = 90) throws {
        transport.battery[2] = percent
        session = DeviceSession(transport: transport)
        let clock = clock
        store = DeviceStore(session: session, clock: { clock.now })
        store.start(); try transport.authorize()
        guard until({ store.snapshot.audioMode != nil }) else { throw BatteryFixtureError.deadline }
        pump(0.06)
        guard store.isReady, store.snapshot.batteryPercent == Int(percent) else { throw BatteryFixtureError.invalidFrame }
    }
}

@main private struct BatteryChecks {
    @MainActor static func main() throws {
        var results: [[String: Any]] = []
        func check(_ name: String, _ success: Bool) { results.append(["name": name, "pass": success]) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reading = batteryReply(percent: 18, charging: 0, flags: 0xa7, at: now)
        check("wire offsets and reserved bytes preserved", reading.voltageRaw == 3959 && reading.percent == 18 && reading.payload[4...5] == [0xaa, 0xbb] && reading.flagsRaw == 0xa7 && reading.powerOffRaw == 3 && reading.firmwareLow == true && reading.isFull == false)
        let unknown = batteryReply(percent: 65535, charging: 99, flags: 0, at: now)
        check("invalid percent and unknown charging are not coerced", unknown.percent == nil && unknown.percentRaw == 65535 && unknown.isCharging == nil && unknown.chargingRaw == 99)
        let short = DeviceReply(decoded: Data([0x81, 1, 2, 0x11, 0, 0, 10, 0]))!
        let incomplete = BatteryReading(reply: short, readAt: now)!
        check("short battery reply retains unknown flags", incomplete.percent == 10 && incomplete.chargingRaw == nil && incomplete.flagsRaw == nil)
        var snapshot = DeviceSnapshot()
        let good = DeviceReply(decoded: Data([0x81, 1, 2, 0x11] + reading.payload))!
        _ = snapshot.apply(good, at: now)
        let batteryDate = snapshot.lastBatteryReadAt
        _ = snapshot.apply(DeviceReply(decoded: Data([0x81, 6, 0x40, 0x11, 0, 0, 0, 0]))!, at: now.addingTimeInterval(60))
        check("unrelated replies cannot refresh battery age", snapshot.lastBatteryReadAt == batteryDate && snapshot.lastReadAt == now.addingTimeInterval(60))
        _ = snapshot.apply(DeviceReply(decoded: Data([0x81, 1, 2, 0x11] + unknown.payload))!, at: now.addingTimeInterval(61))
        check("invalid current percent clears old displayed percent", snapshot.batteryPercent == nil && snapshot.batteryReading?.percentRaw == 65535 && snapshot.lastBatteryReadAt == now.addingTimeInterval(61))

        var policy = BatteryAlertPolicy()
        func evaluate(_ percent: Int, charging: UInt8 = 0, flags: UInt8 = 0, at timestamp: Date? = nil, current: Bool = true) -> BatteryAlert? {
            policy.evaluate(batteryReply(percent: percent, charging: charging, flags: flags, at: timestamp ?? now), at: now, isCurrent: current)
        }
        check("unknown/stale/future/disconnected do not alert", evaluate(10, charging: 77) == nil && evaluate(65535, flags: 4) == nil && evaluate(10, at: now.addingTimeInterval(-91)) == nil && evaluate(10, at: now.addingTimeInterval(1)) == nil && evaluate(10, current: false) == nil && policy.evaluate(incomplete, at: now, isCurrent: true) == nil)
        check("charging and full suppress firmware-low alerts", evaluate(8, charging: 1, flags: 4) == nil && evaluate(8, charging: 0, flags: 12) == nil)
        check("low threshold emits one event", evaluate(20)?.warning.level == .low && evaluate(19) == nil)
        check("unknown or stale reads do not rearm a discharge", evaluate(99, charging: 55) == nil && evaluate(99, at: now.addingTimeInterval(-100)) == nil && evaluate(19) == nil)
        check("critical escalates once", evaluate(10)?.warning.level == .critical && evaluate(8) == nil && evaluate(17) == nil)
        _ = evaluate(21); _ = evaluate(24)
        check("hysteresis prevents threshold jitter", evaluate(20) == nil)
        _ = evaluate(25)
        check("confirmed recovery rearms warning", evaluate(20)?.warning.level == .low)
        _ = evaluate(15, charging: 1)
        check("charging begins next discharge cycle", evaluate(15)?.warning.level == .low)
        _ = evaluate(90)
        check("firmware low can warn above App threshold", evaluate(80, flags: 4)?.warning.firmwareLow == true && evaluate(79, flags: 4) == nil)

        do {
            let h = try BatteryHarness(); defer { h.store.stopForExit() }
            let baseline = h.transport.batteryReads.count
            h.clock.now.addTimeInterval(29); h.store.refreshBatteryIfDue(); pump(0.06)
            check("poll waits for 30 second cadence", h.transport.batteryReads.count == baseline)
            var held: Data?
            h.transport.intercept = { frame in
                if frame[0] & 31 == 1 && frame[1] == 1 && frame[2] == 2 { held = frame; return true }; return false
            }
            h.clock.now.addTimeInterval(1)
            for _ in 0..<100 { h.store.refreshBatteryIfDue() }
            check("due poll coalesces even under repeated ticks", until { held != nil } && h.transport.batteryReads.count == baseline + 1)
            h.transport.battery[2] = 19
            var alerts: [BatteryAlert] = []; h.store.onLowBatteryAlert = { alerts.append($0) }
            try h.transport.respond(held!); h.transport.intercept = nil; pump(0.06)
            check("actual battery reply updates independent age and warning", h.store.snapshot.batteryPercent == 19 && h.store.snapshot.lastBatteryReadAt == h.clock.now && h.store.batteryWarning(at: h.clock.now)?.level == .low && alerts.count == 1)
            h.clock.now.addTimeInterval(30); h.store.refreshBatteryIfDue(); pump(0.06)
            check("repeated low poll is de-duplicated", alerts.count == 1)
            h.transport.battery[2] = 10
            h.clock.now.addTimeInterval(30); h.store.refreshBatteryIfDue(); pump(0.06)
            check("actual Store emits critical escalation", alerts.count == 2 && alerts.last?.warning.level == .critical)
            h.transport.battery[6] = 1
            h.clock.now.addTimeInterval(30); h.store.refreshBatteryIfDue(); pump(0.06)
            check("charging clears in-app warning without another alert", h.store.batteryWarning(at: h.clock.now) == nil && alerts.count == 2)
            h.clock.now.addTimeInterval(91)
            check("silent battery ages stale independently", !h.store.batteryIsFresh(at: h.clock.now) && h.store.batteryWarning(at: h.clock.now) == nil)
            check("battery polling never writes settings", h.transport.settingWrites.isEmpty)
        }
        do {
            let h = try BatteryHarness(); defer { h.store.stopForExit() }
            let baseline = h.transport.batteryReads.count
            h.clock.now.addTimeInterval(30); h.store.editing = true
            for _ in 0..<20 { h.store.refreshBatteryIfDue() }; pump(0.06)
            check("busy tick is dropped before enqueue", h.transport.batteryReads.count == baseline)
            h.store.editing = false
            var blocker: Data?
            h.transport.intercept = { frame in
                if frame[0] & 31 == 1 && frame[1] == 4 && frame[2] == 4 { blocker = frame; return true }; return false
            }
            h.session.read(.version); _ = until { blocker != nil }
            h.store.refreshBatteryIfDue(); h.store.editing = true
            try h.transport.respond(blocker!); pump(0.1)
            check("dequeue recheck cancels poll behind newly busy edit", h.transport.batteryReads.count == baseline && h.store.batteryReadError == nil)
            h.store.editing = false; h.transport.intercept = nil; h.store.refreshBatteryIfDue(); pump(0.06)
            check("cancelled poll does not become retry flood", h.transport.batteryReads.count == baseline)
            h.clock.now.addTimeInterval(30); h.store.refreshBatteryIfDue(); pump(0.06)
            check("next scheduled poll resumes after editing", h.transport.batteryReads.count == baseline + 1)
        }
        do {
            let h = try BatteryHarness(); defer { h.store.stopForExit() }
            let baseline = h.transport.batteryReads.count
            var heldLightRead: Data?
            h.transport.intercept = { frame in
                if frame[0] & 31 == 1 && frame[1] == 11 && frame[2] == 136 { heldLightRead = frame; return true }; return false
            }
            let initial = try SmartLightingSnapshot(connectionID: h.store.connectionID!, payload: h.transport.lights)
            let target = try initial.applying(.init(mode: .allOn, brightness: 8))
            let request = try SmartLightingWriteRequest(expected: initial, target: target, purpose: .feedback)
            let permit = SmartLightingPermit()
            var completed = false
            Task { _ = try? await h.store.applyLighting(request, permit: permit); completed = true }
            check("actual lighting transaction starts held read", until { heldLightRead != nil })
            h.clock.now.addTimeInterval(30)
            for _ in 0..<20 { h.store.refreshBatteryIfDue() }; pump(0.06)
            check("poll cannot interrupt lighting transaction", h.transport.batteryReads.count == baseline)
            permit.revoke(); try h.transport.respond(heldLightRead!); _ = until { completed }
            h.transport.intercept = nil; h.store.refreshBatteryIfDue(); pump(0.06)
            check("poll resumes when lighting releases ownership", h.transport.batteryReads.count == baseline + 1 && h.transport.settingWrites.isEmpty)
        }
        do {
            let h = try BatteryHarness(); defer { h.store.stopForExit() }
            var blocker: Data?
            h.transport.intercept = { frame in
                if frame[0] & 31 == 1 && frame[1] == 4 && frame[2] == 4 { blocker = frame; return true }; return false
            }
            h.session.read(.version); _ = until { blocker != nil }
            let baseline = h.transport.batteryReads.count, originalConnection = h.store.connectionID
            h.clock.now.addTimeInterval(30); h.store.refreshBatteryIfDue()
            try h.transport.deliver([0x8b, 0x0b, 0])
            check("remote loss immediately stales previous battery", !h.store.isReady && !h.store.batteryIsFresh(at: h.clock.now) && h.store.connectionID != originalConnection)
            h.clock.now.addTimeInterval(300)
            for _ in 0..<100 { h.store.refreshBatteryIfDue() }
            check("offline ticks neither wake nor queue reads", h.transport.batteryReads.count == baseline)
            // Complete the held pre-loss command only after the device is back.
            try h.transport.deliver([0x8b, 0x10, 0, 1, 0]); try h.transport.respond(blocker!); pump(0.07)
            check("old-generation queued poll is not replayed after wake", h.transport.batteryReads.count == baseline)
            h.transport.intercept = nil; h.store.stopForExit(); h.clock.now.addTimeInterval(300)
            let stopped = h.transport.batteryReads.count
            for _ in 0..<100 { h.store.refreshBatteryIfDue() }; pump(0.07)
            check("stop prevents future timer work and late polls", h.transport.batteryReads.count == stopped && !h.store.connected)
        }
        do {
            let h = try BatteryHarness(); defer { h.store.stopForExit() }
            h.transport.intercept = { $0[0] & 31 == 1 && $0[1] == 1 && $0[2] == 2 }
            h.clock.now.addTimeInterval(30); h.store.refreshBatteryIfDue()
            check("battery read timeout marks sample unconfirmed", until { h.store.batteryReadError != nil } && !h.store.batteryIsFresh(at: h.clock.now) && h.store.batteryWarning(at: h.clock.now) == nil)
            let attempts = h.transport.batteryReads.count
            for _ in 0..<100 { h.store.refreshBatteryIfDue() }; pump(0.05)
            check("read failure cannot hot-loop retry", h.transport.batteryReads.count == attempts)
        }
        do {
            let h = try BatteryHarness(); defer { h.store.stopForExit() }
            let baseline = h.transport.batteryReads.count
            h.clock.now.addTimeInterval(-120); h.store.refreshBatteryIfDue(); pump(0.06)
            check("wall-clock rollback cannot suspend polling indefinitely", h.transport.batteryReads.count == baseline + 1 && h.store.snapshot.lastBatteryReadAt == h.clock.now)
        }
        do {
            let h = try BatteryHarness(); defer { h.store.stopForExit() }
            h.transport.intercept = { $0[0] & 31 == 1 && $0[1] == 1 && $0[2] == 2 }
            h.clock.now.addTimeInterval(-120); h.store.refreshBatteryIfDue()
            check("rollback recovery timeout remains an unconfirmed reading", until { h.store.batteryReadError != nil })
            let attempts = h.transport.batteryReads.count
            for _ in 0..<100 { h.store.refreshBatteryIfDue() }; pump(0.05)
            check("future old sample cannot hot-loop failed rollback recovery", h.transport.batteryReads.count == attempts)
        }
        do {
            let h = try BatteryHarness(); defer { h.store.stopForExit() }
            let baseline = h.transport.batteryReads.count
            h.clock.now.addTimeInterval(30)
            let mode = RunLoop.Mode("VibekeyBatteryOwnedTrackingMode")
            CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: mode.rawValue as CFString))
            let keeper = Timer(timeInterval: 0.02, repeats: true) { _ in }
            RunLoop.main.add(keeper, forMode: mode); defer { keeper.invalidate() }
            let deadline = Date().addingTimeInterval(1.2)
            while Date() < deadline {
                _ = RunLoop.main.run(mode: mode, before: min(deadline, Date().addingTimeInterval(0.04)))
            }
            check("real background timer dispatches in common tracking mode", h.transport.batteryReads.count == baseline + 1)
        }
        let failed = results.filter { $0["pass"] as? Bool != true }
        let report: [String: Any] = ["status": failed.isEmpty ? "PASS" : "FAIL", "checks": results, "physicalDeviceWrites": 0, "notificationSends": 0, "notificationPermissionRequests": 0]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        if !failed.isEmpty { exit(1) }
    }
}
