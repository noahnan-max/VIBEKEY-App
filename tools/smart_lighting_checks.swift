import Foundation
import VibekeyCore

// Pure synthetic snapshots and an in-memory device adapter. No DeviceSession,
// HIDTransport, App, user settings or physical LEDs are instantiated.
@MainActor private final class Clock {
    var now: TimeInterval = 100
    var sleeps: [TimeInterval] = []
    func sleep(_ seconds: TimeInterval) async throws {
        sleeps.append(seconds)
        let end = now + seconds
        while now < end { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 1_000_000) }
        try Task.checkCancellation()
    }
}

@MainActor private final class Gate {
    var entered = false
    var released = false
    func wait() async throws {
        entered = true
        for _ in 0..<1_000 {
            if released { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw CheckFailure(message: "Synthetic gate was not released")
    }
}

private struct CheckFailure: Error { let message: String }

@MainActor private final class Device {
    let clock: Clock
    var value: SmartLightingSnapshot
    var reads = 0
    var requests: [SmartLightingWriteRequest] = []
    var steps: [(SmartLightingWriteRequest.Purpose, SmartLightingWriteStep, TimeInterval)] = []
    var beforeRead: (() async throws -> Void)?
    var beforeStep: ((Int, SmartLightingWriteRequest, SmartLightingPermit) async throws -> Void)?
    var failRead = false
    var failAfterStep: Int?
    var omitFailureReadback = false
    var mismatchedReturn: SmartLightingSnapshot?

    init(value: SmartLightingSnapshot, clock: Clock) { self.value = value; self.clock = clock }
    func read(_ id: UUID) async throws -> SmartLightingSnapshot {
        reads += 1
        if let beforeRead { try await beforeRead() }
        if failRead { throw SmartLightingFailure.unavailable }
        guard value.connectionID == id else { throw SmartLightingFailure.connectionChanged }
        return value
    }
    func apply(_ request: SmartLightingWriteRequest, _ permit: SmartLightingPermit) async throws -> SmartLightingSnapshot {
        requests.append(request)
        var last = request.expected
        for (index, step) in request.steps.enumerated() {
            if let beforeStep { try await beforeStep(index, request, permit) }
            guard permit.isValid else { throw SmartLightingApplyError(.cancelled, lastReadback: last) }
            guard value.connectionID == request.connectionID else { throw SmartLightingApplyError(.connectionChanged) }
            guard value == step.expected else { throw SmartLightingApplyError(.ownershipChanged, lastReadback: value) }
            value = step.target
            steps.append((request.purpose, step, clock.now))
            // A complete synthetic readback occurs after this step, unless the
            // fixture explicitly models a lost reply to an already-sent write.
            if failAfterStep == index {
                failAfterStep = nil
                throw SmartLightingApplyError(.transport, lastReadback: omitFailureReadback ? nil : value)
            }
            last = value
        }
        return mismatchedReturn ?? value
    }
    var adapter: SmartLightingController.Adapter { .init(read: { [self] in try await read($0) }, apply: { [self] in try await apply($0, $1) }) }
}

@MainActor private struct Fixture {
    let clock: Clock
    let device: Device
    let controller: SmartLightingController
    let original: SmartLightingSnapshot
    init(mode: SmartLightingMode = .off, brightness: Int = 5, preferences: UserDefaults? = nil) throws {
        clock = Clock(); original = try makeSnapshot(mode: mode, brightness: brightness)
        device = Device(value: original, clock: clock)
        let clock = self.clock
        controller = SmartLightingController(adapter: device.adapter, clock: { clock.now }, sleep: { try await clock.sleep($0) }, preferences: preferences)
        controller.setConnection(id: original.connectionID, ready: true)
    }
    func begin(_ state: SmartLightingState) { controller.updateState(state); controller.setEnabled(true) }
    func advance(_ amount: TimeInterval) async {
        // Let newly-created async sleepers register their relative deadline
        // before advancing virtual time; otherwise the test changes the epoch.
        await settle(); clock.now += amount; await settle()
    }
    func restore() async -> SmartLightingController.RestoreResult {
        let task = Task { await controller.stopAndRestore() }
        await settle(); await advance(2)
        return await task.value
    }
}

private func makeSnapshot(id: UUID = UUID(), mode: SmartLightingMode = .off, brightness: Int = 5,
                          records: [UInt8] = Array(20...39), selectors: [UInt8] = [255, 3]) throws -> SmartLightingSnapshot {
    try .init(connectionID: id, payload: selectors + [UInt8(mode.rawValue), UInt8(brightness)] + records)
}
@MainActor private func settle() async {
    for _ in 0..<8 { try? await Task.sleep(nanoseconds: 1_000_000) }
}

@main struct SmartLightingChecks {
    @MainActor static func main() async {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ pass: Bool) { checks.append(["name": name, "pass": pass]) }
        func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        do {
            let base = try makeSnapshot()
            check("snapshot preserves all four opaque five-byte records", base.workRecords == Array(20...39) && base.rawPayload.count == 24)
            check("short payload rejected", rejects { _ = try SmartLightingSnapshot(connectionID: base.connectionID, payload: Array(base.rawPayload.prefix(23))) })
            var invalid = base.rawPayload; invalid[2] = 3
            check("unknown mode rejected", rejects { _ = try SmartLightingSnapshot(connectionID: base.connectionID, payload: invalid) })
            invalid = base.rawPayload; invalid[3] = 21
            check("out-of-range readback brightness rejected", rejects { _ = try SmartLightingSnapshot(connectionID: base.connectionID, payload: invalid) })
            let padded = try SmartLightingSnapshot(connectionID: base.connectionID, payload: base.rawPayload + [99, 99])
            let selectorVariant = try makeSnapshot(id: base.connectionID, selectors: [1, 0])
            check("CAS ignores selectors and trailing padding", padded == base && selectorVariant == base)
            check("CAS rejects changed connection", try makeSnapshot() != base)
            check("CAS detects all opaque work bytes", try makeSnapshot(id: base.connectionID, records: Array(19...38)) != base)
            check("intent rejects invalid brightness", rejects { _ = try SmartLightingIntent(mode: .allOn, brightness: -1) } && rejects { _ = try SmartLightingIntent(mode: .allOn, brightness: 21) })
            check("unknown or idle source can preserve original", try SmartLightingPolicy.intent(for: .standby) == nil)
            check("Agent running uses directly controlled all-on brightness", try SmartLightingPolicy.intent(for: .running) == SmartLightingIntent(mode: .allOn, brightness: 8))
            check("approval is visibly brighter than running at the default setting", try SmartLightingPolicy.intent(for: .awaitingApproval) == SmartLightingIntent(mode: .allOn, brightness: 16))
            check("approval has no expiry timer", SmartLightingPolicy.automaticRestoreDelay(for: .awaitingApproval) == nil)
            check("completion hint expires but running never infers completion", SmartLightingPolicy.automaticRestoreDelay(for: .completed) == 1.2 && SmartLightingPolicy.automaticRestoreDelay(for: .running) == nil)
            check("Agent settings present five states", SmartLightingState.agentStates == [.standby, .running, .awaitingApproval, .completed, .failed])
            for state in SmartLightingState.allCases {
                if let intent = try SmartLightingPolicy.intent(for: state) {
                    let target = try base.applying(intent)
                    let req = try SmartLightingWriteRequest(expected: base, target: target, purpose: .feedback)
                    check("known fields only for \(state.rawValue)", target.workRecords == base.workRecords && req.frames.allSatisfy { $0.count == 64 && Array($0.prefix(4)) == [1, 11, 136, 4] && [1, 2].contains($0[4]) && $0[5] == 0 && $0.dropFirst(8).allSatisfy { $0 == 0 } })
                }
            }
            let target = try base.applying(.init(mode: .allOn, brightness: 8))
            let req = try SmartLightingWriteRequest(expected: base, target: target, purpose: .feedback)
            check("brightness precedes mode on turn-on", req.frames.count == 2 && req.frames[0][4] == 2 && req.frames[0][7] == 8 && req.frames[1][4] == 1 && req.frames[1][6] == 1)
            check("step CAS includes exact intermediate snapshot", req.steps[0].expected == base && req.steps[1].expected == req.steps[0].target && req.steps[1].target == target)
            let back = try SmartLightingWriteRequest(expected: target, target: base, purpose: .restore)
            check("restore dark mode before original brightness", back.frames.count == 2 && back.frames[0][4] == 1 && back.frames[0][6] == 0 && back.frames[1][4] == 2 && back.frames[1][7] == 5)
            check("no-op write plan empty", try SmartLightingWriteRequest(expected: base, target: selectorVariant, purpose: .restore).frames.isEmpty)
            let other = try makeSnapshot()
            check("plan rejects cross-connection restore", rejects { _ = try SmartLightingWriteRequest(expected: base, target: other, purpose: .restore) })
            let changedRecords = try makeSnapshot(id: base.connectionID, records: Array(19...38))
            check("plan rejects changing opaque work records", rejects { _ = try SmartLightingWriteRequest(expected: base, target: changedRecords, purpose: .restore) })
            let permit = SmartLightingPermit()
            DispatchQueue.concurrentPerform(iterations: 100) { index in if index % 9 == 0 { permit.revoke() }; _ = permit.isValid }
            check("permit revocation remains false across concurrent reads", !permit.isValid)

            do {
                let f = try Fixture()
                f.controller.updateState(.awaitingApproval); f.controller.setBrightness(9); await settle()
                check("disabled and preview state make no adapter calls", f.device.reads == 0 && f.device.requests.isEmpty && !f.controller.enabled)
                f.controller.setEnabled(true); await settle()
                check("original is borrowed and full readback confirms approval", f.controller.hasBorrowedSettings && f.controller.latestReadback == f.device.value && f.controller.lastConfirmedState == .awaitingApproval && f.controller.status == .confirmed)
                let count = f.device.steps.count
                await f.advance(3_600)
                check("approval stays without timer or repeated writes", f.controller.state == .awaitingApproval && f.device.steps.count == count && f.controller.enabled)
                let restore = await f.restore()
                check("explicit stop restores exact original config", restore == .restored && f.device.value == f.original && !f.controller.hasBorrowedSettings && !f.controller.enabled)
                check("restoration includes fresh ownership read", f.device.reads == 2 && f.device.requests.last?.purpose == .restore)
            }
            do {
                let f = try Fixture(mode: .allOn, brightness: 16); f.begin(.awaitingApproval); await settle()
                check("already matching light confirms by read without write", f.device.requests.isEmpty && f.device.reads == 1 && f.controller.status == .confirmed)
                let result = await f.restore()
                check("matching original restore needs no write", result == .restored && f.device.requests.isEmpty)
            }
            do {
                let f = try Fixture(); f.begin(.running); await settle()
                f.device.value = try f.device.value.applying(.init(mode: .allOn, brightness: 17))
                let manuallyChanged = f.device.value
                let result = await f.restore()
                check("fresh-read drift relinquishes without overriding manual change", result == .relinquished && f.device.value == manuallyChanged && f.device.requests.count == 1 && !f.controller.hasBorrowedSettings)
            }
            do {
                let f = try Fixture(); let gate = Gate()
                f.device.beforeStep = { index, _, _ in if index == 1 { try await gate.wait() } }
                f.begin(.awaitingApproval); await settle()
                check("fixture reaches between-frame pause", gate.entered && f.device.steps.count == 1)
                f.controller.manualLightingWillChange(); gate.released = true; await settle()
                check("manual edit revokes queued second frame and discards late ownership", f.device.steps.count == 1 && f.controller.status == .relinquished && f.controller.latestReadback == nil && !f.controller.enabled)
            }
            do {
                let f = try Fixture(); let gate = Gate()
                f.device.beforeStep = { index, request, _ in if request.purpose == .feedback && index == 1 { try await gate.wait() } }
                f.begin(.awaitingApproval); await settle()
                let stop = Task { await f.controller.stopAndRestore() }; await settle()
                gate.released = true; await settle(); await f.advance(2)
                let result = await stop.value
                check("disable between frames restores last real partial readback", result == .restored && f.device.value == f.original && f.device.steps.filter { $0.0 == .feedback }.count == 1 && f.device.requests.last?.expected.brightness == 16)
            }
            do {
                let f = try Fixture(); let gate = Gate()
                f.device.beforeStep = { _, _, _ in try await gate.wait() }
                f.begin(.running); await settle()
                f.controller.setConnection(id: nil, ready: false)
                let replacement = try makeSnapshot(mode: .allOn, brightness: 13)
                f.device.value = replacement; f.controller.setConnection(id: replacement.connectionID, ready: true)
                gate.released = true; await settle(); await f.advance(120)
                check("reconnection retains opt-in but never receives stale feedback or old restore", f.device.steps.isEmpty && f.device.value == replacement && f.controller.enabled && f.controller.state == .standby && f.controller.latestReadback == nil && f.controller.lastConfirmation == nil)
                f.controller.updateState(.running); await settle()
                check("fresh state after reconnect reads and borrows the replacement config", f.controller.status == .confirmed && f.device.value.connectionID == replacement.connectionID && f.controller.latestReadback == f.device.value)
                _ = await f.restore()
            }
            do {
                let f = try Fixture(); f.controller.setDevicePriority(true); f.begin(.awaitingApproval); await settle()
                check("device priority defers reads and writes", f.device.reads == 0 && f.device.requests.isEmpty && f.controller.status == .waitingForDeviceAccess)
                f.controller.updateState(.running); f.controller.setDevicePriority(false); await settle()
                check("device priority release applies only latest state", f.device.requests.count == 1 && f.device.value.mode == .allOn && f.controller.lastConfirmedState == .running)
                _ = await f.restore()
            }
            do {
                let f = try Fixture()
                f.begin(.running)
                // Same actor turn: a worker exists, but has not consumed work.
                f.controller.setDevicePriority(true); await settle()
                check("device priority before worker starts preserves queued feedback without I/O", f.device.reads == 0 && f.device.requests.isEmpty && f.controller.status == .waitingForDeviceAccess)
                f.controller.setDevicePriority(false); await settle()
                check("queued feedback resumes when pre-start device priority releases", f.device.requests.count == 1 && f.controller.lastConfirmedState == .running && f.device.value.mode == .allOn)
                _ = await f.restore()
            }
            do {
                let f = try Fixture(); f.begin(.awaitingApproval); await settle(); await f.advance(2)
                f.controller.setEnabled(false)
                // Stop's restore worker is scheduled before this priority edge.
                f.controller.setDevicePriority(true); await settle()
                check("device priority before restore worker starts retains original lease", f.device.requests.count == 1 && f.controller.hasBorrowedSettings && f.controller.status == .waitingForDeviceAccess)
                f.controller.setDevicePriority(false); await settle()
                check("queued original restore resumes without another stop request", f.device.requests.count == 2 && f.device.requests.last?.purpose == .restore && f.device.value == f.original && !f.controller.hasBorrowedSettings && f.controller.status == .restored)
            }
            do {
                let f = try Fixture(); let gate = Gate()
                f.device.beforeStep = { index, request, _ in if request.purpose == .feedback && index == 1 { try await gate.wait() } }
                f.begin(.awaitingApproval); await settle()
                f.controller.setDevicePriority(true); gate.released = true; await settle()
                check("configuration start revokes queued frame but keeps actual partial readback", f.device.steps.count == 1 && f.controller.latestReadback == f.device.value && f.controller.status == .waitingForDeviceAccess)
                let deferred = await f.controller.stopAndRestore()
                check("restore reports deferred while configuration owns device priority", deferred == .deferred && f.controller.hasBorrowedSettings)
                f.controller.setDevicePriority(false); await f.advance(2)
                check("configuration completion allows pending original restore", f.device.value == f.original && !f.controller.hasBorrowedSettings)
            }
            do {
                let f = try Fixture(); let gate = Gate()
                f.device.beforeStep = { index, request, _ in if request.purpose == .feedback && index == 1 { try await gate.wait() } }
                f.begin(.completed); await settle()
                f.controller.updateState(.failed); f.controller.updateState(.awaitingApproval)
                gate.released = true; await settle(); await f.advance(2)
                check("new state coalesces and revokes obsolete queued frames", f.device.requests.count == 2 && f.controller.lastConfirmedState == .awaitingApproval && !f.device.requests.contains { $0.target.brightness == 8 && $0.target.mode == .allOn && $0.operationID == f.device.requests[0].operationID })
                check("partial feedback preserved across coalescing", f.device.requests[1].expected.brightness == 4 && f.device.requests[1].expected.mode == .off)
                _ = await f.restore()
            }
            do {
                let f = try Fixture(); f.begin(.running); await settle()
                f.controller.updateState(.failed); await f.advance(2)
                f.controller.updateState(.running); await f.advance(2)
                check("three ordinary Agent changes consume only three slots", f.device.requests.count == 3 && f.controller.lastConfirmedState == .running)
                f.controller.updateState(.failed); await f.advance(2)
                check("fourth ordinary event waits with one slot reserved", f.device.requests.count == 3 && f.controller.status == .limitReached)
                f.controller.updateState(.awaitingApproval); await settle()
                check("new approval uses reserved slot without waiting sixty seconds", f.device.requests.count == 4 && f.clock.now < 160 && f.controller.lastConfirmedState == .awaitingApproval && f.controller.status == .confirmed)
                f.controller.updateState(.awaitingApproval); await settle()
                check("already applied approval does not consume extra slot", f.device.requests.count == 4)
                f.controller.setBrightness(9); await f.advance(5)
                check("reservation never exceeds four total feedback events", f.device.requests.count == 4 && f.controller.status == .limitReached && f.device.value.brightness == 16)
                _ = await f.restore()
            }
            do {
                let f = try Fixture(); f.begin(.awaitingApproval); await settle()
                f.controller.updateState(.running); await f.advance(2)
                f.controller.updateState(.failed); await f.advance(2)
                f.controller.updateState(.running); await f.advance(2)
                check("approval used first still permits three ordinary events", f.device.requests.count == 4 && f.controller.lastConfirmedState == .running)
                _ = await f.restore()
            }
            do {
                let f = try Fixture(); f.begin(.awaitingApproval); await settle()
                for b in [9, 10, 11] { f.controller.setBrightness(b); await settle(); await f.advance(2) }
                check("four feedback transactions accepted across real intervals", f.device.requests.count == 4 && f.device.requests.allSatisfy { $0.purpose == .feedback })
                f.controller.setBrightness(12); await settle(); await f.advance(5)
                check("rate budget holds latest approval without auto restore", f.device.requests.count == 4 && f.controller.enabled && f.controller.state == .awaitingApproval && f.controller.status == .limitReached)
                await f.advance(60)
                check("rate window applies coalesced latest brightness", f.device.requests.count == 5 && f.device.value.brightness == 20 && f.controller.status == .confirmed)
                let times = f.device.steps.enumerated().filter { $0.offset == 0 || $0.element.2 != f.device.steps[$0.offset - 1].2 }.map { $0.element.2 }
                check("transactions maintain 1.5-second minimum", zip(times, times.dropFirst()).allSatisfy { $1 - $0 >= 1.5 })
                _ = await f.restore()
            }
            do {
                let f = try Fixture(); f.begin(.awaitingApproval); await settle()
                for b in [9, 10, 11] { f.controller.setBrightness(b); await settle(); await f.advance(2) }
                f.controller.setBrightness(12); await settle()
                let result = await f.restore()
                check("restoration bypasses feedback quota", result == .restored && f.device.value == f.original && f.device.requests.last?.purpose == .restore)
                let count = f.device.requests.count
                f.begin(.running); await settle(); await f.advance(3)
                check("new lease cannot reset global feedback quota", f.device.requests.count == count && f.controller.status == .limitReached)
                f.controller.setEnabled(false); await settle()
            }
            do {
                let f = try Fixture(); let gate = Gate()
                f.device.beforeStep = { _, request, _ in if request.purpose == .feedback { try await gate.wait() } }
                f.begin(.completed); await settle(); await f.advance(8)
                check("completion hint duration does not start before readback", f.controller.state == .completed && f.controller.lastConfirmedState == nil && f.device.steps.isEmpty)
                gate.released = true; await settle(); await f.advance(1)
                check("completed hint remains for its confirmed duration", f.controller.state == .completed && f.controller.lastConfirmedState == .completed)
                await f.advance(0.3); await f.advance(2)
                check("confirmed completion hint restores original once", f.controller.state == .standby && f.device.value == f.original && f.device.requests.filter { $0.purpose == .restore }.count == 1)
                f.controller.setEnabled(false)
            }
            do {
                let f = try Fixture(); f.begin(.completed); await settle()
                f.controller.updateState(.awaitingApproval); await settle(); await f.advance(2)
                await f.advance(300)
                check("old completion timer never clears newer approval", f.controller.state == .awaitingApproval && f.controller.lastConfirmedState == .awaitingApproval && f.device.value.brightness == 16)
                _ = await f.restore()
            }
            do {
                let f = try Fixture(); f.device.failAfterStep = 0; f.begin(.awaitingApproval); await settle(); await f.advance(2)
                check("second-stage failure compensates only verified first-stage state", f.device.value == f.original && f.device.requests.count == 2 && f.device.requests[1].purpose == .restore && f.device.requests[1].expected.brightness == 16 && f.device.steps.filter { $0.0 == .feedback }.count == 1)
            }
            do {
                let f = try Fixture(); f.device.failAfterStep = 0; f.device.omitFailureReadback = true
                f.begin(.awaitingApproval); await settle(); await f.advance(2)
                check("lost readback never guesses partial state or restores blindly", f.device.requests.count == 1 && f.device.value != f.original && f.controller.status == .relinquished)
            }
            do {
                let f = try Fixture(); f.device.mismatchedReturn = try makeSnapshot(id: f.original.connectionID, mode: .workMode, brightness: 19)
                f.begin(.awaitingApproval); await settle(); await f.advance(2)
                check("unplanned adapter result relinquishes without success", f.controller.status == .relinquished && f.controller.lastConfirmedState == nil && f.device.requests.count == 1)
            }
            do {
                let f = try Fixture(); f.device.failRead = true; f.begin(.running); await settle()
                check("initial read failure makes no writes or success", f.device.requests.isEmpty && !f.controller.enabled && f.controller.status == .unavailable && f.controller.lastConfirmedState == nil)
            }
            do {
                let f = try Fixture(); f.begin(.awaitingApproval); await settle()
                f.device.failAfterStep = 0
                let result = await f.restore()
                let count = f.device.requests.count
                await f.advance(120)
                check("failed restore preserves partial readback without retry loop", result == .unconfirmed && f.controller.hasBorrowedSettings && f.controller.latestReadback == f.device.value && f.controller.status == .restoreUnconfirmed && f.device.requests.count == count)
                let retry = await f.restore()
                check("explicit restore retry uses retained latest readback", retry == .restored && f.device.value == f.original)
            }
            do {
                let f = try Fixture(); var backups = 0
                f.controller.prepareBorrow = { _ in backups += 1; throw SmartLightingFailure.unavailable }
                f.begin(.running); await settle()
                check("failed private backup blocks every physical write", backups == 1 && f.device.requests.isEmpty && !f.controller.hasBorrowedSettings && f.controller.status == .backupUnavailable && f.controller.lastConfirmation == nil)
            }
            do {
                let f = try Fixture(); var backups: [SmartLightingSnapshot] = []
                f.controller.prepareBorrow = { backups.append($0) }
                f.begin(.running); await settle()
                f.controller.updateState(.awaitingApproval); await settle(); await f.advance(2)
                check("one complete baseline is backed up before multiple feedback states", backups == [f.original] && f.controller.lastConfirmation?.rawPayload == f.device.value.rawPayload)
                _ = await f.restore()
            }
            do {
                let name = "vibekey.lighting.fixture." + UUID().uuidString
                let preferences = UserDefaults(suiteName: name)!
                defer { preferences.removePersistentDomain(forName: name) }
                let f = try Fixture(preferences: preferences)
                f.controller.setEnabled(true); await settle()
                check("opt-in without a real state never writes the device", f.controller.requestedEnabled && f.controller.status == .waitingForSource && f.device.reads == 0)
                f.controller.updateState(.running); await settle()
                check("confirmed trace contains actual running readback", f.controller.lastConfirmation?.state == .running && f.controller.lastConfirmation?.brightness == 8 && f.controller.lastConfirmation?.wroteSettings == true)
                let stop = Task { await f.controller.stopAndRestore(preserveEnabledIntent: true) }
                await settle(); await f.advance(2); _ = await stop.value
                check("exit restores hardware while preserving follow preference", f.device.value == f.original && f.controller.requestedEnabled && !f.controller.enabled && f.controller.lastConfirmation?.restored == true)
                let reopened = try Fixture(preferences: preferences); await settle()
                check("relaunch remembers opt-in but waits for fresh source", reopened.controller.requestedEnabled && reopened.controller.enabled && reopened.controller.status == .waitingForSource && reopened.device.reads == 0)
                reopened.controller.manualLightingWillChange()
                let afterManual = try Fixture(preferences: preferences)
                check("manual lighting edit permanently relinquishes remembered intent", !afterManual.controller.requestedEnabled && !afterManual.controller.enabled)
            }
            do {
                let f = try Fixture(); f.clock.now = .nan; f.begin(.running); await settle()
                check("nonfinite scheduling clock blocks all I/O", f.device.reads == 0 && f.device.requests.isEmpty && !f.controller.enabled)
            }
            do {
                let f = try Fixture(); f.begin(.running); await settle(); f.clock.now -= 1
                f.controller.updateState(.awaitingApproval); await settle()
                check("backward clock stops new writes and keeps recoverable original", f.device.requests.count == 1 && f.controller.hasBorrowedSettings && f.controller.status == .restoreUnconfirmed)
                f.clock.now += 10; _ = await f.restore()
            }
            do {
                let f = try Fixture(); f.device.beforeRead = { f.clock.now = .infinity }
                f.begin(.running); await settle()
                check("clock becomes nonfinite during read cannot reach apply", f.device.requests.isEmpty && !f.controller.enabled && f.controller.hasBorrowedSettings && f.controller.status == .restoreUnconfirmed)
            }
        } catch { check("unexpected error: \(error)", false) }
        let failed = checks.filter { $0["pass"] as? Bool == false }.count
        let result: [String: Any] = ["schemaVersion": 1, "status": failed == 0 ? "PASS" : "FAIL", "failed": failed,
                                    "checkCount": checks.count, "checks": checks, "syntheticAdapterOnly": true,
                                    "hardwareOpened": false, "userConfigurationRead": false, "UIAcceptance": "NOT_RUN",
                                    "physicalLEDBehavior": "NOT_RUN", "firmwarePersistence": "UNKNOWN"]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if failed > 0 { exit(1) }
    }
}
