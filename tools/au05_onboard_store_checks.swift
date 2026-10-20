import AppKit
import Foundation
@testable import VibekeyCore

private final class DeviceFixture: DeviceTransporting {
    var onReport: ((Data) -> Void)?
    var onConnection: ((Bool, String) -> Void)?
    var shortcuts: [UInt8: AU05OnboardShortcut] = [:]
    var shortcutWrites = 0, lightWrites = 0
    var brightness: UInt8 = 8
    var failBrightnessReadback = false
    var connected = false
    init() throws {
        let entries: [[AU05ShortcutEntry]] = [[.init(page:3,usage:1)],[.init(page:2,usage:40)],[.init(page:2,usage:42)],[.init(page:3,usage:16)],[.init(page:7,usage:6)],[.init(page:7,usage:5)]]
        for index: UInt8 in 0...5 { shortcuts[index] = try AU05OnboardShortcut(index: index, entries: entries[Int(index)]) }
    }
    func start() { connected = true; onConnection?(true, "fixture") }
    func stop() { connected = false; onConnection?(false, "fixture") }
    @discardableResult func send(report: Data) throws -> Int32 {
        let frame = Array(AU05Codec.decodeReport(report)!)
        if frame[0] == 6, frame[2] == 5 {
            var value: UInt32 = 0
            for n in 0..<4 { value |= UInt32(frame[5+n]) << (n*8) }
            value ^= 0xd9f4e04c
            deliver([0x86,2,5,0x11,5] + (0..<4).map { UInt8(truncatingIfNeeded:value >> ($0*8)) }); return 0
        }
        guard frame[3] == 1 || frame[3] == 4 || frame[3] == 2 else { return 0 }
        let read = frame[3] == 1
        var payload: [UInt8] = []
        if frame[1] == 6, frame[2] == 0x50 {
            let index = frame[4]
            if !read {
                shortcutWrites += 1
                let reply = DeviceReply(decoded: Data([0x81,6,0x50,0x11] + Array(frame.dropFirst(4))))!
                shortcuts[index] = try AU05OnboardShortcut(reply: reply, index: index)
            }
            payload = Array(try shortcuts[index]!.writeFrame().dropFirst(4).prefix(12))
            if read {
                var stale = payload; stale[0] = index == 0 ? 1 : 0
                deliver([0x81,6,0x50,0x11] + stale)
            }
        } else if frame[1] == 11, frame[2] == 0x88 {
            if !read { lightWrites += 1; if !failBrightnessReadback { brightness = frame[7] } }
            payload = [0,0,1,brightness] + Array(repeating:0,count:20)
        } else if frame[0] == 6, frame[2] == 0x0a { payload = [1] }
        else if frame[1] == 4, frame[2] == 4 { payload = [0,0,0,0,0,0,4,5,1,0,0,0,0,0,0] }
        else if frame[1] == 1, frame[2] == 2 { payload = [0,0,80,0] }
        else if frame[1] == 1, frame[2] == 0x90 { payload = [1,100,0,100,0] }
        else { payload = [0,0,0,0] }
        deliver([0x80 | (frame[0] & 31),frame[1],frame[2],read ? 0x11 : 0x10] + payload)
        return 0
    }
    private func deliver(_ bytes: [UInt8]) {
        let report = try! AU05Codec.outputReport(plaintext: Data(bytes) + Data(repeating:0,count:64-bytes.count))
        DispatchQueue.main.asyncAfter(deadline:.now()+0.005) { [weak self] in if self?.connected == true { self?.onReport?(report) } }
    }
}

@main struct AU05OnboardStoreChecks {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        var complete = false, result = 1
        Task { @MainActor in
            do { try await run(); result = 0 } catch { fputs("FAIL: \(error)\n",stderr) }
            complete = true
        }
        let deadline = Date().addingTimeInterval(35)
        while !complete && Date()<deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        exit(complete ? Int32(result) : 2)
    }
    @MainActor private static var count = 0
    @MainActor private static func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw NSError(domain: name,code:1) }; count += 1
    }
    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date()<deadline { try await Task.sleep(nanoseconds:20_000_000) }
        try check(condition(), "Asynchronous state did not converge")
    }
    @MainActor private static func run() async throws {
        let fixture = try DeviceFixture(), session = DeviceSession(transport: fixture)
        let device = DeviceStore(session: session)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vibekey-store-check-"+UUID().uuidString)
        let preferenceDomain = "vibekey-onboard-check-"+UUID().uuidString
        let preferences = UserDefaults(suiteName:preferenceDomain)!
        preferences.set(true,forKey:"hardwareEnhancementsEnabled.v1")
        defer { preferences.removePersistentDomain(forName:preferenceDomain) }
        let store = AU05OnboardStore(device: device,directory: directory,preferences:preferences)
        store.start(); device.start(); defer { device.stopForExit() }
        try await wait { store.configurations.count == 6 && !store.isBusy }
        try check(fixture.shortcutWrites == 0, "Startup must only read device configuration")
        try check(store.configuration(for:"key.1")?.recordedShortcut?.keyCode == 36, "Wrong-index replies must not complete the actual request")
        store.record(RecordedShortcut(keyCode:0,modifiers:0),triggerID:"key.1")
        store.record(RecordedShortcut(keyCode:11,modifiers:0x100000),triggerID:"key.1")
        try await wait { !store.hasPendingChanges && !store.isBusy }
        try check(fixture.shortcutWrites == 1 && fixture.shortcuts[1]?.recordedShortcut == RecordedShortcut(keyCode:11,modifiers:0x100000), "Rapid edits save directly to device even with the retired mode preference set")
        store.record(RecordedShortcut(keyCode:63,modifiers:0),triggerID:"key.1")
        try await Task.sleep(nanoseconds:400_000_000)
        try check(fixture.shortcutWrites == 1 && store.error != nil, "Unsupported input is not posted")
        store.record(RecordedShortcut(keyCode:12,modifiers:0),triggerID:"key.2")
        let flushed = await store.flush()
        try check(flushed && fixture.shortcutWrites == 2, "Quit flushes valid pending field")
        store.record(RecordedShortcut(keyCode:14,modifiers:0),triggerID:"key.0")
        fixture.stop(); try await Task.sleep(nanoseconds:450_000_000)
        try check(fixture.shortcutWrites == 2, "Disconnect discards no hardware state and sends no stale write")
        fixture.start(); try await Task.sleep(nanoseconds:700_000_000)
        try check(fixture.shortcutWrites == 2 && store.hasPendingChanges, "Reconnect does not replay pending edit")
        store.reloadFromDevice()
        try await wait { !store.isBusy && !store.hasPendingChanges && store.configurations.count == 6 }
        try check(fixture.shortcutWrites == 2, "Explicit reread is still read-only")
        device.stageBrightness(2);device.stageBrightness(4);device.stageBrightness(9)
        try await Task.sleep(nanoseconds:200_000_000)
        try check(fixture.lightWrites == 0, "Staging a slider never writes before commit or exit flush")
        let bright = await device.flushAutomaticChanges()
        try check(bright && fixture.lightWrites == 1 && device.snapshot.lightBrightness == 9, "Latest brightness is queued and read back")
        fixture.failBrightnessReadback = true;device.stageBrightness(10);device.requestBrightness(10)
        let failed = await device.flushAutomaticChanges()
        try check(!failed && device.error != nil, "Failed brightness must block successful flush")
        device.stageBrightness(9);device.requestBrightness(9)
        let acknowledged = await device.flushAutomaticChanges()
        try check(acknowledged, "Explicit existing value resolves failed pending target")
        print("{\"status\":\"PASS\",\"checks\":\(count),\"physicalDeviceWrites\":0,\"systemInputPosted\":0}")
    }
}
