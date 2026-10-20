import Foundation
@testable import VibekeyCore

private enum FixtureError: Error { case transport, deadline, invalidFixture }
private final class MemoryTransport: DeviceTransporting {
    var onReport: ((Data) -> Void)?
    var onConnection: ((Bool, String) -> Void)?
    var sent: [Data] = []
    var applied: [Data] = []
    var lights: [UInt8] = [255, 3, 0, 5] + Array(20...39)
    var intercept: ((Data) throws -> Bool)?
    private var generation = 0
    private var connected = false
    var lightReads: [Data] { sent.filter { $0[0] & 31 == 1 && $0[1] == 11 && $0[2] == 136 && $0[3] & 1 == 1 } }
    var lightWrites: [Data] { sent.filter { $0[0] & 31 == 1 && $0[1] == 11 && $0[2] == 136 && $0[3] & 1 == 0 } }
    func start() { connected = true; generation += 1; onConnection?(true, "synthetic receiver attached") }
    func stop() { guard connected else { return }; connected = false; generation += 1; onConnection?(false, "synthetic receiver detached") }
    func send(report: Data) throws -> Int32 {
        guard let frame = AU05Codec.decodeReport(report) else { throw FixtureError.invalidFixture }
        sent.append(frame)
        if try intercept?(frame) == true { return 0 }
        if frame[0] & 31 == 1 || (frame[0] & 31 == 6 && frame[1] == 3 && frame[2] == 10) {
            commit(frame); respondLater(frame)
        }
        return 0
    }
    func commit(_ frame: Data) {
        guard frame[0] & 31 == 1, frame[1] == 11, frame[2] == 136, frame[3] & 1 == 0 else { return }
        if frame[4] == 1 { lights[2] = frame[6] }
        if frame[4] == 2 { lights[3] = frame[7] }
        applied.append(frame)
    }
    func respondLater(_ frame: Data) {
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { [weak self] in
            guard let self, connected, generation == token else { return }
            try? respond(frame)
        }
    }
    func respond(_ frame: Data) throws {
        let read = frame[3] & 1 == 1
        let payload: [UInt8]
        switch (frame[0] & 31, frame[1], frame[2]) {
        case (6, 3, 10): payload = [1]
        case (1, 11, 136): payload = lights
        case (1, 1, 2): payload = [0, 0, 60, 0]
        case (1, 4, 4): payload = Array(repeating: 0, count: 15)
        case (1, 1, 144): payload = [0, 0, 0, 0, 0]
        case (1, 1, 42): payload = [1]
        default: payload = [0, 0, 0, 0]
        }
        try deliver([128 | (frame[0] & 31), frame[1], frame[2], read ? 17 : 16] + payload)
    }
    func deliver(_ prefix: [UInt8]) throws {
        guard prefix.count <= 64 else { throw FixtureError.invalidFixture }
        onReport?(try AU05Codec.outputReport(plaintext: Data(prefix) + Data(repeating: 0, count: 64 - prefix.count)))
    }
    func authorize() throws {
        guard let frame = sent.last(where: { $0[0] & 31 == 6 && $0[1] == 2 && $0[2] == 5 }) else { throw FixtureError.invalidFixture }
        let challenge = (0..<4).reduce(UInt32(0)) { $0 | UInt32(frame[5 + $1]) << ($1 * 8) }
        let response = challenge ^ 0xd9f4e04c
        try deliver([134, 2, 5, 17, 5] + (0..<4).map { UInt8(truncatingIfNeeded: response >> (8 * $0)) })
    }
}

@MainActor private final class Outcome<T> {
    var result: Result<T, Error>?
    var completions = 0
    init(_ work: @escaping @MainActor () async throws -> T) {
        Task { do { result = .success(try await work()) } catch { result = .failure(error) }; completions += 1 }
    }
    var success: T? { try? result?.get() }
    var failure: Error? { if case .failure(let error) = result { return error }; return nil }
}
@MainActor private func pump(_ seconds: Double = 0.01) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
@MainActor @discardableResult private func until(_ predicate: () -> Bool, timeout: Double = 3) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < end { pump(0.005) }
    return predicate()
}
@MainActor private func finish<T>(_ result: Outcome<T>) throws {
    guard until({ result.result != nil }) else { throw FixtureError.deadline }
}
@MainActor private struct Harness {
    let transport: MemoryTransport
    let session: DeviceSession
    let store: DeviceStore
    init() throws {
        transport = MemoryTransport(); session = DeviceSession(transport: transport)
        store = DeviceStore(session: session)
        store.start(); try transport.authorize()
        guard until({ transport.sent.contains { $0[0] & 31 == 1 && $0[1] == 6 && $0[2] == 81 && $0[3] & 1 == 1 } }) else { throw FixtureError.deadline }
        pump(0.06)
        guard store.isReady, store.connectionID != nil else { throw FixtureError.invalidFixture }
    }
    var initial: SmartLightingSnapshot { try! .init(connectionID: store.connectionID!, payload: transport.lights) }
    func request() throws -> SmartLightingWriteRequest {
        try .init(expected: initial, target: initial.applying(.init(mode: .allOn, brightness: 8)), purpose: .feedback)
    }
}

@main private struct LightingAdapterChecks {
    @MainActor static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ pass: Bool) { checks.append(["name": name, "pass": pass]) }
        func error(_ result: Outcome<SmartLightingSnapshot>) -> SmartLightingApplyError? { result.failure as? SmartLightingApplyError }
        do {
            // Execute the actual session queue; the revoked request is behind
            // a held ordinary read, so rejection cannot be an enqueue shortcut.
            do {
                let h = try Harness(); defer { h.store.stopForExit() }
                var held: Data?, callbackCount = 0, cancellation = false, nextRead = false, guardCalls = 0
                h.transport.intercept = { frame in
                    if frame[0] & 31 == 1 && frame[1] == 1 && frame[2] == 2 && frame[3] & 1 == 1 { held = frame; return true }
                    return false
                }
                h.session.read(.battery)
                let permit = SmartLightingPermit()
                h.session.write(.lights, frame: try DeviceControls.lightMode(1), shouldSend: { guardCalls += 1; return permit.isValid }) { result in
                    callbackCount += 1
                    if case .failure(let e) = result, case SessionError.cancelled = e { cancellation = true }
                }
                h.session.read(.sleep) { if case .success = $0 { nextRead = true } }
                check("queued write guard not called at enqueue", guardCalls == 0 && held != nil)
                permit.revoke(); try h.transport.respond(held!); check("follower finishes after queued cancellation", until { nextRead })
                check("actual dequeue guard blocks revoked frame exactly once", h.transport.lightWrites.isEmpty && guardCalls == 1 && callbackCount == 1 && cancellation)
                pump(0.08); check("cancelled queue request cannot later replay", h.transport.lightWrites.isEmpty && callbackCount == 1)
            }
            do {
                let h = try Harness(); defer { h.store.stopForExit() }
                let request = try h.request(), reads = h.transport.lightReads.count
                let result = Outcome { try await h.store.applyLighting(request, permit: SmartLightingPermit()) }; try finish(result)
                check("real adapter completes both known-field writes with readback", result.success == request.target && h.transport.applied.count == 2 && h.transport.lightReads.count - reads == 3)
                check("actual queued frames preserve mode order and opaque records", h.transport.applied[0][4] == 2 && h.transport.applied[1][4] == 1 && Array(h.transport.lights[4..<24]) == request.expected.workRecords)
                check("DeviceStore receives final public snapshot", h.store.snapshot.lightMode == 1 && h.store.snapshot.lightBrightness == 8 && result.completions == 1)
                let mismatched = Outcome { try await h.store.readLighting(connection: UUID()) }; try finish(mismatched)
                check("wrong generation fails before queue read", mismatched.failure as? SmartLightingFailure == .connectionChanged && h.transport.lightReads.count - reads == 3)
            }
            do {
                let h = try Harness(); defer { h.store.stopForExit() }
                let request = try h.request(); h.transport.lights[3] = 13
                let result = Outcome { try await h.store.applyLighting(request, permit: SmartLightingPermit()) }; try finish(result)
                check("fresh CAS mismatch sends no write", error(result)?.reason == .ownershipChanged && h.transport.lightWrites.isEmpty)
                check("CAS conflict retains actual conflicting readback", error(result)?.lastReadback?.brightness == 13 && error(result)?.lastReadback?.workRecords == request.expected.workRecords)
            }
            do {
                let h = try Harness(); defer { h.store.stopForExit() }
                let request = try h.request(), reads = h.store.diagnostics.readTimeouts
                h.transport.intercept = { frame in
                    if frame[0] & 31 == 1 && frame[2] == 136 && frame[3] & 1 == 1 {
                        h.transport.onReport?(Data([85, 0, 0, 0, 0, 0, 0, 0])); return true
                    }; return false
                }
                let result = Outcome { try await h.store.applyLighting(request, permit: SmartLightingPermit()) }; try finish(result)
                check("truncated HID readback times out without invented payload", error(result)?.reason == .transport && error(result)?.lastReadback == nil && h.transport.lightWrites.isEmpty && h.store.diagnostics.readTimeouts == reads + 1)
            }
            do {
                let h = try Harness(); defer { h.store.stopForExit() }
                let request = try h.request(); h.transport.lights[2] = 3
                let result = Outcome { try await h.store.applyLighting(request, permit: SmartLightingPermit()) }; try finish(result)
                check("complete packet with unknown mode is not an accepted snapshot", error(result)?.reason == .invalidSnapshot && error(result)?.lastReadback == nil && h.transport.lightWrites.isEmpty)
            }
            do {
                let h = try Harness(); defer { h.store.stopForExit() }
                let request = try h.request(); var heldRead: Data?
                h.transport.intercept = { frame in
                    if frame[0] & 31 == 1 && frame[2] == 136 && frame[3] & 1 == 1 && h.transport.applied.count == 1 { heldRead = frame; return true }
                    return false
                }
                let result = Outcome { try await h.store.applyLighting(request, permit: SmartLightingPermit()) }
                check("post-write query reached after ACK", until { heldRead != nil })
                check("write ACK alone never completes adapter", result.result == nil && h.transport.applied.count == 1)
                h.transport.intercept = nil; try h.transport.respond(heldRead!); try finish(result)
                check("full queries allow both steps to finish", result.success == request.target && h.transport.applied.count == 2)
            }
            do {
                let h = try Harness(); defer { h.store.stopForExit() }
                let request = try h.request(), permit = SmartLightingPermit(), reads = h.transport.lightReads.count
                h.transport.intercept = { frame in
                    if frame[0] & 31 == 1 && frame[2] == 136 && frame[3] & 1 == 0 {
                        h.transport.commit(frame); permit.revoke(); h.transport.respondLater(frame); return true
                    }; return false
                }
                let result = Outcome { try await h.store.applyLighting(request, permit: permit) }; try finish(result)
                check("revoked after physical send still performs complete readback", error(result)?.reason == .cancelled && error(result)?.lastReadback == request.steps[0].target && h.transport.lightReads.count - reads == 2)
                check("revocation blocks subsequent step", h.transport.applied.count == 1 && h.transport.lightWrites.count == 1)
            }
            do {
                let h = try Harness(); defer { h.store.stopForExit() }
                let request = try h.request()
                h.transport.intercept = { frame in
                    if frame[0] & 31 == 1 && frame[2] == 136 && frame[3] & 1 == 0 && h.transport.lightWrites.count == 2 { throw FixtureError.transport }
                    return false
                }
                let result = Outcome { try await h.store.applyLighting(request, permit: SmartLightingPermit()) }; try finish(result)
                check("second send failure preserves first complete readback", error(result)?.reason == .transport && error(result)?.lastReadback == request.steps[0].target && h.transport.applied.count == 1)
            }
            do {
                let h = try Harness(); defer { h.store.stopForExit() }
                let request = try h.request()
                h.transport.intercept = { frame in
                    if frame[0] & 31 == 1 && frame[2] == 136 && frame[3] & 1 == 1 && h.transport.applied.count == 2 {
                        h.transport.onReport?(Data([85, 0])); return true
                    }; return false
                }
                let result = Outcome { try await h.store.applyLighting(request, permit: SmartLightingPermit()) }; try finish(result)
                check("second write ACK plus missing readback never becomes final target", error(result)?.reason == .transport && error(result)?.lastReadback == request.steps[0].target && error(result)?.lastReadback != request.target && h.transport.applied.count == 2)
            }
            do {
                let h = try Harness(); defer { h.store.stopForExit() }
                let request = try h.request()
                h.transport.intercept = { frame in
                    if frame[0] & 31 == 1 && frame[2] == 136 && frame[3] & 1 == 1 && h.transport.applied.count == 1 { h.transport.lights[4] = 77 }
                    return false
                }
                let result = Outcome { try await h.store.applyLighting(request, permit: SmartLightingPermit()) }; try finish(result)
                check("post-write conflict retains full real readback and stops next step", error(result)?.reason == .readbackMismatch && error(result)?.lastReadback?.workRecords.first == 77 && h.transport.applied.count == 1)
            }
            do {
                let h = try Harness(); defer { h.store.stopForExit() }
                let request = try h.request(), permit = SmartLightingPermit(); var readReplied = false
                h.transport.intercept = { frame in
                    if frame[0] & 31 == 1 && frame[2] == 136 && frame[3] & 1 == 1 {
                        try h.transport.respond(frame); readReplied = true; return true
                    }; return false
                }
                let result = Outcome { try await h.store.applyLighting(request, permit: permit) }
                check("generation fixture read returned before queued write", until { readReplied })
                pump(0.01) // write is now queued behind the real 40ms quiet interval
                try h.transport.deliver([139, 11, 0])
                try finish(result)
                check("generation change rejects queued old write even with live permit", permit.isValid && h.store.connectionID != request.connectionID && error(result)?.reason == .connectionChanged && h.transport.lightWrites.isEmpty)
            }
            do {
                let h = try Harness(); defer { h.store.stopForExit() }
                let request = try h.request(); var disconnected = false
                h.transport.intercept = { frame in
                    if !disconnected && frame[0] & 31 == 1 && frame[2] == 136 && frame[3] & 1 == 0 {
                        disconnected = true; h.transport.commit(frame); h.transport.stop(); h.transport.start(); try h.transport.authorize(); return true
                    }; return false
                }
                let result = Outcome { try await h.store.applyLighting(request, permit: SmartLightingPermit()) }; try finish(result); pump(0.6)
                check("physical reconnect changes identity and never replays remaining old frame", h.store.connectionID != request.connectionID && error(result)?.reason == .connectionChanged && h.transport.applied.count == 1 && h.transport.lightWrites.count == 1)
                check("old readback stays explicitly tagged with old generation", error(result)?.lastReadback?.connectionID == request.connectionID)
            }
            do {
                let h = try Harness(); defer { h.store.stopForExit() }
                let request = try h.request(); var held: Data?
                h.transport.intercept = { frame in
                    if frame[0] & 31 == 1 && frame[2] == 136 && frame[3] & 1 == 1 && held == nil { held = frame; return true }
                    return false
                }
                let first = Outcome { try await h.store.applyLighting(request, permit: SmartLightingPermit()) }
                check("first concurrent fixture holds a real read", until { held != nil })
                let second = Outcome { try await h.store.applyLighting(request, permit: SmartLightingPermit()) }; try finish(second)
                check("concurrent adapter cannot interleave independent lighting transaction", error(second)?.reason == .unavailable && error(second)?.lastReadback == nil)
                h.transport.intercept = nil; try h.transport.respond(held!); try finish(first)
                check("first operation remains usable after concurrency rejection", first.success == request.target)
            }
            do {
                let h = try Harness(); defer { h.store.stopForExit() }
                var calls = 0, writesAtCallback = -1
                h.store.onManualLightingChange = { calls += 1; writesAtCallback = h.transport.lightWrites.count }
                h.store.setBrightness(11)
                check("manual change callback runs before actual queued write", calls == 1 && writesAtCallback == 0)
                check("original manual apply still writes and reads requested value", until { !h.store.editing } && h.store.snapshot.lightBrightness == 11 && h.store.error == nil)
            }
        } catch { check("unexpected fixture failure: \(error)", false) }
        let failed = checks.filter { $0["pass"] as? Bool == false }.count
        let receipt: [String: Any] = ["schemaVersion": 1, "status": failed == 0 ? "PASS" : "FAIL", "checkCount": checks.count,
                                     "failed": failed, "checks": checks, "productionDeviceSessionAndStore": true,
                                     "transport": "memory-only with actual AU05Codec framing", "realHIDOpened": false,
                                     "userPreferencesRead": false, "physicalLEDBehavior": "NOT_RUN", "UI": "NOT_RUN"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        if failed > 0 { exit(1) }
    }
}
