import Foundation
@testable import VibekeyCore

@MainActor private var checks = 0
@MainActor private func check(_ condition: Bool, _ name: String) {
    guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }; checks += 1
}
private enum FixtureFailure: Error { case failure }
@MainActor private final class Fixture {
    var value: AU05OnboardShortcut
    var available = true
    var reads = 0, writes = 0
    var writing: ((Int, AU05OnboardShortcut) throws -> Void)?
    var reading: ((Int) throws -> Void)?
    let archive: AU05ShortcutArchive
    init(_ value: AU05OnboardShortcut, name: String) throws {
        self.value = value
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vibekey-onboard-check-" + name + "-" + UUID().uuidString)
        archive = AU05ShortcutArchive(directory: directory)
    }
    var adapter: AU05ShortcutAdapter {
        AU05ShortcutAdapter(available: { self.available }, read: { index in
            self.reads += 1; try self.reading?(self.reads)
            guard index == self.value.index else { throw FixtureFailure.failure }; return self.value
        }, write: { value in
            check((try? self.archive.pending()) != nil, "Backup must precede hardware write")
            self.writes += 1
            if let writing = self.writing { try writing(self.writes, value) } else { self.value = value }
        })
    }
}

@main struct AU05OnboardChecks {
    @MainActor static func main() async throws {
        let original = try AU05OnboardShortcut(index: 1, entries: [.init(page: 2, usage: 40)])
        let target = try original.replacing(entries: AU05OnboardShortcut.entries(for: RecordedShortcut(keyCode: 0, modifiers: 0x120000)))
        let frame = try target.writeFrame()
        check(frame.count == 64 && Array(frame.prefix(7)) == [1,6,0x50,4,1,1,3], "Wire header and entry count")
        check(Array(frame[7..<13]) == [3,2,3,8,2,4] && frame[15] == 0, "Vendor modifier categories and keyboard usage")
        check(frame.dropFirst(16).allSatisfy { $0 == 0 }, "Reserved bytes remain zero")
        let reply = DeviceReply(decoded: Data([0x81,6,0x50,0x11]) + frame.dropFirst(4))!
        check(try AU05OnboardShortcut(reply: reply, index: 1) == target, "Readback decoder")
        do { _ = try AU05OnboardShortcut(reply: reply, index: 2); check(false, "Wrong slot accepted") } catch { check(true, "Wrong slot rejected") }
        var invalid = Array(frame); invalid[0] = 0x81; invalid[3] = 0x11; invalid[6] = 5
        do { _ = try AU05OnboardShortcut(reply: DeviceReply(decoded: Data(invalid))!, index: 1); check(false, "Oversized count accepted") } catch { check(true, "Oversized count rejected") }
        for code: UInt16 in [59,62,56,60,58,61,55,54] {
            let entries = try AU05OnboardShortcut.entries(for: RecordedShortcut(keyCode: code, modifiers: 0))
            let value = try AU05OnboardShortcut(index: 0, entries: entries)
            check(value.recordedShortcut?.keyCode == code && value.recordedShortcut?.modifiers == 0, "Sided modifier roundtrip")
        }
        for code: UInt16 in [0,36,51,48,49,53,122,111,123,124,125,126,83,92] {
            let entries = try AU05OnboardShortcut.entries(for: RecordedShortcut(keyCode: code, modifiers: 0))
            check(try AU05OnboardShortcut(index: 0, entries: entries).recordedShortcut?.keyCode == code, "Keyboard map roundtrip")
        }
        do { _ = try AU05OnboardShortcut.entries(for: RecordedShortcut(keyCode: 63, modifiers: 0)); check(false, "Unverified Fn encoded") } catch { check(true, "Unverified Fn blocked") }
        check(try AU05OnboardShortcut.entries(for: RecordedShortcut(keyCode: 40, modifiers: 0x1a0000)).count == 4, "Three modifiers plus key fit exactly four entries")
        do { _ = try AU05OnboardShortcut.entries(for: RecordedShortcut(keyCode: 40, modifiers: 0x1e0000)); check(false, "Fifth entry overwrote event type") } catch { check(true, "Oversized chord rejected") }
        let up = try AU05OnboardShortcut(index: 5, entries: [.init(page: 7, usage: 5)])
        let down = try AU05OnboardShortcut(index: 4, entries: [.init(page: 7, usage: 6)])
        check(up.scrollDirection == 1 && down.scrollDirection == -1, "Live verified wheel codes")
        let empty = try original.replacing(entries: [])
        check(try empty.writeFrame()[6] == 0, "Empty mapping is explicit")

        var router = AU05OnboardActionRouter()
        let a = try AU05OnboardShortcut(index: 0, entries: [.init(page: 3, usage: 1), .init(page: 2, usage: 4)])
        let b = try AU05OnboardShortcut(index: 1, entries: [.init(page: 3, usage: 1), .init(page: 2, usage: 5)])
        check(router.handle("a", pressed: true, configuration: a).count == 2, "Modifier before key")
        check(router.handle("a", pressed: true, configuration: a).isEmpty, "Duplicate down suppressed")
        check(router.handle("b", pressed: true, configuration: b).count == 1, "Shared modifier has one down")
        check(router.handle("a", pressed: false, configuration: b).count == 1, "Release uses original owner and retains shared modifier")
        let released = router.handle("b", pressed: false, configuration: a)
        check(released.count == 2 && released.last == .key(keyCode: 59, pressed: false, modifiers: 0), "Last owner releases modifier")
        check(router.releaseAll().isEmpty, "No leaked keys")
        check(router.handle("wheel", pressed: true, configuration: down) == [.scroll(lines: -1, modifiers: 0)], "Wheel is one impulse")
        let rotatedKey = try AU05OnboardShortcut(index: 4, entries: [.init(page: 2, usage: 40)])
        check(router.handle("wheel-key", pressed: true, configuration: rotatedKey).count == 2 && router.releaseAll().isEmpty, "Rotated key releases immediately")

        let success = try Fixture(original, name: "success")
        let engine = try AU05ShortcutTransaction(archive: success.archive)
        try await engine.save(original: original, target: target, adapter: success.adapter)
        check(success.writes == 1 && success.value == target && engine.recovery == nil, "Verified write commits")
        check(try AU05ShortcutTransaction(archive: success.archive).recovery == nil, "Successful journal survives restart")
        let attrs = try FileManager.default.attributesOfItem(atPath: success.archive.directory.path)
        check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Backup directory is private")

        let stale = try Fixture(target, name: "stale")
        do { try await AU05ShortcutTransaction(archive: stale.archive).save(original: original, target: target, adapter: stale.adapter); check(false, "Stale baseline accepted") }
        catch { check(stale.writes == 0, "Compare-before-write blocks stale state") }

        let timeout = try Fixture(original, name: "timeout")
        timeout.writing = { number, value in timeout.value = value; if number == 1 { throw FixtureFailure.failure } }
        do { try await AU05ShortcutTransaction(archive: timeout.archive).save(original: original, target: target, adapter: timeout.adapter); check(false, "Timed-out ACK committed") }
        catch { check(timeout.writes == 2 && timeout.value == original, "Late ACK state is read and restored") }

        let unreadable = try Fixture(original, name: "readback")
        unreadable.reading = { number in if number == 2 { throw FixtureFailure.failure } }
        do { try await AU05ShortcutTransaction(archive: unreadable.archive).save(original: original, target: target, adapter: unreadable.adapter); check(false, "Failed readback committed") }
        catch { check(unreadable.writes == 2 && unreadable.value == original, "Readback failure restores original") }

        let failed = try Fixture(original, name: "recovery")
        failed.writing = { number, value in if number == 1 { failed.value = value }; throw FixtureFailure.failure }
        let failedEngine = try AU05ShortcutTransaction(archive: failed.archive)
        do { try await failedEngine.save(original: original, target: target, adapter: failed.adapter); check(false, "Unconfirmed recovery hidden") }
        catch { check(failedEngine.recovery != nil, "Unconfirmed restoration blocks continuation") }
        let resumed = try AU05ShortcutTransaction(archive: failed.archive)
        check(resumed.recovery != nil, "Pending restoration survives restart")
        failed.writing = nil
        try await resumed.recover(adapter: failed.adapter)
        check(failed.value == original && resumed.recovery == nil, "Explicit recovery verifies original")

        let lost = try Fixture(original, name: "disconnect")
        lost.writing = { _, value in lost.value = value; lost.available = false }
        let lostEngine = try AU05ShortcutTransaction(archive: lost.archive)
        do { try await lostEngine.save(original: original, target: target, adapter: lost.adapter); check(false, "Disconnected transaction committed") }
        catch { check(lost.writes == 1 && lostEngine.recovery != nil, "Disconnect never replays a write") }

        let foreign = try Fixture(original, name: "foreign")
        let external = try original.replacing(entries: [.init(page: 2, usage: 6)])
        foreign.writing = { _, _ in foreign.value = external }
        let foreignEngine = try AU05ShortcutTransaction(archive: foreign.archive)
        do { try await foreignEngine.save(original: original, target: target, adapter: foreign.adapter); check(false, "Foreign modification committed") }
        catch { check(foreign.writes == 1 && foreign.value == external && foreignEngine.recovery != nil, "Recovery preserves unexpected concurrent state") }

        let unchanged = try Fixture(original, name: "unchanged")
        try await AU05ShortcutTransaction(archive: unchanged.archive).save(original: original, target: original, adapter: unchanged.adapter)
        check(unchanged.writes == 0, "No-op does not write device")
        let unsafe = try Fixture(original, name: "unsafe")
        try FileManager.default.createDirectory(at: unsafe.archive.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        do { try await AU05ShortcutTransaction(archive: unsafe.archive).save(original: original, target: target, adapter: unsafe.adapter); check(false, "Unsafe backup permissions accepted") }
        catch { check(unsafe.writes == 0, "Unsafe backup blocks hardware writes") }
        let damaged = try Fixture(original, name: "damaged")
        try FileManager.default.createDirectory(at: damaged.archive.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let damagedPath = damaged.archive.directory.appendingPathComponent("last-transaction.json")
        try Data("damaged recovery record".utf8).write(to: damagedPath)
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath: damagedPath.path)
        do { _ = try AU05ShortcutTransaction(archive: damaged.archive); check(false, "Damaged recovery record ignored") }
        catch { check(damaged.writes == 0, "Damaged recovery blocks new writes") }
        let linked = try Fixture(original, name: "symlink")
        try FileManager.default.createDirectory(at: linked.archive.directory, withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
        try FileManager.default.createSymbolicLink(at: linked.archive.directory.appendingPathComponent("last-transaction.json"), withDestinationURL: damagedPath)
        do { _ = try AU05ShortcutTransaction(archive: linked.archive); check(false, "Symlink recovery path accepted") }
        catch { check(linked.writes == 0, "Symlink recovery blocked") }
        print("{\"status\":\"PASS\",\"checks\":\(checks),\"physicalDeviceWrites\":0,\"systemInputPosted\":0}")
    }
}
