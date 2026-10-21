import AppKit
import Foundation
import Darwin
import VibekeyCore

private enum SyntheticFailure: Error { case action }
private final class FaultReader {
    var calls = 0
    var failOnceAt: Int?
    var failFrom: Int?
    var thirdFrom: Int?
    var third: Data?
    func read(_ url: URL) throws -> Data {
        calls += 1
        if calls == failOnceAt || (failFrom.map { calls >= $0 } ?? false) { throw SyntheticFailure.action }
        if let threshold = thirdFrom, calls >= threshold, let third { return third }
        return try Data(contentsOf: url)
    }
}
private func require(_ condition: Bool, _ message: String) throws { if !condition { throw RadialMenuError.invalid(message) } }
private func document(_ count: Int = 3, enabled: Bool = true, activation:RadialActivation = .middleHold) -> RadialMenuDocument {
    RadialMenuDocument(schemaVersion:activation == .middleHold ? 1:(activation == .knobPress ? 2:3),enabled: enabled, items: (0..<count).map {
        RadialMenuItem(name: "合成动作 \($0)", steps: [WorkflowStep(kind: .delay, seconds: Double($0) / 100)])
    },activation:activation)
}
@MainActor private final class ActionGate {
    var continuation: CheckedContinuation<Void, Never>?
    var released = false
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor private final class RadialFixture {
    let store: RadialMenuStore
    var time: TimeInterval = 10
    var physicalFlags: UInt64 = 0
    var authorized = true, connected = true, busy = false, focusValid = true
    var generation = 1
    var captures = 0
    var forwarded: [(String, Bool)] = []
    var replays: [UInt64] = []
    var events: [CGEvent] = []
    var executed: [[WorkflowStep]] = []
    var actionFailure = false
    var actionGate: ActionGate?
    lazy var original = AU05OriginalActions(authorized: { self.authorized }, physicalModifiers: { CGEventFlags(rawValue: self.physicalFlags) }, deliver: { self.events.append($0) })
    lazy var controller: RadialMenuController = {
        let value = RadialMenuController(store: store, showsPanel: false, observeWorkspace: false,
            clock: { self.time }, modifiers: { self.physicalFlags }, captureTarget: {
                self.captures += 1
                let captured = self.generation
                return RadialHostTarget(processID: pid_t(10000 + captured), isCurrent: { self.focusValid && self.generation == captured })
            }, executeAction: { steps in
                self.executed.append(steps)
                if let gate = self.actionGate { await gate.wait() }
                if self.actionFailure { throw SyntheticFailure.action }
            })
        value.hardwareEligible = { self.authorized && self.connected && !self.busy && !self.original.hasHeldModifier }
        value.previewEligible = { !self.busy }
        value.forward = { id, pressed in
            self.forwarded.append((id, pressed))
            self.original.handle(id, pressed: pressed)
        }
        value.replayMiddleTap = { flags in
            self.replays.append(flags)
            self.original.handle("key.1", pressed: true, physicalFlagsOverride: flags)
            self.original.handle("key.1", pressed: false, physicalFlagsOverride: flags)
        }
        value.replayTap = { id, flags in
            self.original.handle(id, pressed: true, physicalFlagsOverride: flags)
            self.original.handle(id, pressed: false, physicalFlagsOverride: flags)
        }
        return value
    }()
    init(directory: URL, enabled: Bool = true, count: Int = 3, reader: FaultReader? = nil,activation:RadialActivation = .middleHold) throws {
        store = RadialMenuStore(directory: directory, readData: { url in
            if let reader { return try reader.read(url) }
            return try Data(contentsOf: url)
        })
        store.draft = document(count, enabled: enabled,activation:activation)
        try require(store.save(), "Synthetic radial configuration could not be saved")
    }
    func event(_ id: String, _ pressed: Bool, after delta: TimeInterval = 0) { time += delta; controller.handleHardware(id, pressed: pressed) }
    func tap(after: TimeInterval = 0.1) { event("key.1", true, after: after); event("key.1", false, after: 0.1) }
    func openByRelease() throws {
        event("key.1", true, after: 0.1); event("key.1", false, after: 0.5)
        try require(controller.isPresented && !controller.hasPendingHold, "Long release did not open a menu")
    }
    var middleForwards: Int { forwarded.filter { $0.0 == "key.1" && $0.1 }.count }
    var returnEvents: [CGEvent] { events.filter { ($0.type == .keyDown || $0.type == .keyUp) && $0.getIntegerValueField(.keyboardEventKeycode) == 36 } }
    var scrollEvents: [CGEvent] { events.filter { $0.type == .scrollWheel } }
    func stop() { controller.shutdown(); actionGate?.release(); original.releaseAll() }
}

@MainActor private func waitFor(_ label: String, _ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while !condition() && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
    try require(condition(), "Timed out: " + label)
}

@main @MainActor private struct RadialIntegrationChecks {
    static func main() async throws {
        guard CommandLine.arguments.contains("--ui-probe"),
              let rootArgument = CommandLine.arguments.first(where: { $0.hasPrefix("--probe-directory=") }),
              let reportArgument = CommandLine.arguments.first(where: { $0.hasPrefix("--report=") }) else { throw SyntheticFailure.action }
        let root = URL(fileURLWithPath: String(rootArgument.dropFirst("--probe-directory=".count)), isDirectory: true)
        let report = URL(fileURLWithPath: String(reportArgument.dropFirst("--report=".count)))
        try require(root.path.hasPrefix(NSHomeDirectory() + "/Library/Caches/Vibekey/OwnedProbes/radial-v32-") && root.resolvingSymlinksInPath() == root,
                    "Only owned synthetic store directories are permitted")
        let filter = CommandLine.arguments.first(where: { $0.hasPrefix("--case-filter=") }).map { String($0.dropFirst("--case-filter=".count)) }
        if let filter { _ = try NSRegularExpression(pattern: filter) }
        var rows: [[String: Any]] = [], fixtures: [RadialFixture] = []
        var directoryIndex = 0
        func directory() throws -> URL {
            directoryIndex += 1
            let result = root.appendingPathComponent("case-\(directoryIndex)", isDirectory: true)
            try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return result
        }
        func fixture(enabled: Bool = true, count: Int = 3, reader: FaultReader? = nil,activation:RadialActivation = .middleHold) throws -> RadialFixture {
            let fixture = try RadialFixture(directory: directory(), enabled: enabled, count: count, reader: reader,activation:activation)
            fixtures.append(fixture); return fixture
        }
        func check(_ name: String, _ body: @MainActor () async throws -> Void) async {
            if let filter, name.range(of: filter, options: .regularExpression) == nil { return }
            print("START " + name)
            do { try await body(); rows.append(["name": name, "status": "PASS"]) }
            catch { rows.append(["name": name, "status": "FAIL", "error": error.localizedDescription]) }
            print("END " + name + " " + (rows.last?["status"] as? String ?? "UNKNOWN"))
        }

        await check("Fresh daily preset is ready and round-trips without touching legacy files") {
            let path = try directory(), snapshot = Data("synthetic snapshot sentinel".utf8), workflows = Data("synthetic workflow sentinel".utf8)
            try snapshot.write(to: path.appendingPathComponent("snapshot.json")); try workflows.write(to: path.appendingPathComponent("workflows.json"))
            let store = RadialMenuStore(directory: path)
            try require(store.configuration.enabled && store.configuration.activation == .knobPress && store.configuration.items.count == 12 && WindowOverviewAction.matches(store.configuration.items[0].steps) && store.error == nil, "Incomplete fresh radial preset")
            try require(RadialMenuStore(directory: path).configuration == store.configuration, "New default configuration did not round-trip")
            try require(try Data(contentsOf: path.appendingPathComponent("snapshot.json")) == snapshot && Data(contentsOf: path.appendingPathComponent("workflows.json")) == workflows,
                        "Radial initialization changed legacy settings or workflow bytes")
            let mode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
            try require(mode?.intValue == 0o600, "Fresh radial file is not private")
        }
        await check("Actual store draft changes publish only after valid save and preserve UUID order on reload") {
            let store = RadialMenuStore(directory: try directory()), initial = store.configuration
            store.draft = document(10); store.move(store.draft.items[0].id, by: 1)
            try require(store.configuration == initial, "Unsaved draft changed active configuration")
            try require(store.save(), "Valid reordered configuration did not save")
            let saved = store.configuration
            try require(RadialMenuStore(directory: store.fileURL.deletingLastPathComponent()).configuration == saved, "Saved order or IDs changed on reload")
            let bytes = try Data(contentsOf: store.fileURL)
            store.add()
            try require(!store.save() && store.configuration == saved && (try Data(contentsOf: store.fileURL)) == bytes,
                        "Invalid new item replaced the last-good configuration")
            store.resetDraft(); try require(store.draft == saved, "Reset did not restore the saved configuration")
        }
        for (name, bytes) in [("bad JSON", Data("{".utf8)), ("future schema", Data("{\"schemaVersion\":99,\"enabled\":true,\"items\":[]}".utf8))] {
            await check("Store rejects and preserves " + name) {
                let path = try directory(), file = path.appendingPathComponent("radial-menu.json")
                try bytes.write(to: file)
                let store = RadialMenuStore(directory: path)
                try require(store.error != nil && !store.configuration.enabled, "Invalid store was activated")
                store.draft = document(); try require(!store.save() && (try Data(contentsOf: file)) == bytes, "Invalid store was overwritten")
                store.resetDraft(); store.draft = document()
                try require(!store.save() && (try Data(contentsOf: file)) == bytes, "Reset bypassed the invalid-file save latch")
            }
        }
        await check("Oversized store is rejected before decoding and not replaced") {
            let path = try directory(), file = path.appendingPathComponent("radial-menu.json")
            FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o600])
            let handle = try FileHandle(forWritingTo: file); try handle.truncate(atOffset: UInt64(RadialMenuValidation.maximumDataBytes + 1)); try handle.close()
            let store = RadialMenuStore(directory: path); store.draft = document()
            try require(store.error != nil && !store.save(), "Oversized store accepted")
            let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
            try require(size?.intValue == RadialMenuValidation.maximumDataBytes + 1, "Oversized original changed")
        }
        for dangling in [false, true] {
            await check("Store refuses file symlink dangling=\(dangling)") {
                let path = try directory(), outside = path.appendingPathComponent("outside.json"), storePath = path.appendingPathComponent("store", isDirectory: true)
                try FileManager.default.createDirectory(at: storePath, withIntermediateDirectories: false)
                let sentinel = Data("synthetic outside sentinel".utf8)
                if !dangling { try sentinel.write(to: outside) }
                let file = storePath.appendingPathComponent("radial-menu.json")
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
                let store = RadialMenuStore(directory: storePath); store.draft = document()
                try require(store.error != nil && !store.save(), "File symlink allowed a save")
                try require((try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) == outside.path, "File symlink replaced")
                if dangling { try require(!FileManager.default.fileExists(atPath: outside.path), "Dangling destination was created") }
                else { try require(try Data(contentsOf: outside) == sentinel, "Symlink destination changed") }
            }
            await check("Store refuses directory and ancestor symlink dangling=\(dangling)") {
                let path = try directory(), target = path.appendingPathComponent("target", isDirectory: true), linked = path.appendingPathComponent("link", isDirectory: true)
                if !dangling { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
                try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
                for directory in [linked, linked.appendingPathComponent("nested", isDirectory: true)] {
                    let store = RadialMenuStore(directory: directory); store.draft = document()
                    try require(store.error != nil && !store.save(), "Directory link path allowed save")
                }
                try require(!FileManager.default.fileExists(atPath: target.appendingPathComponent("radial-menu.json").path)
                            && !FileManager.default.fileExists(atPath: target.appendingPathComponent("nested/radial-menu.json").path), "Redirected directory received configuration")
            }
        }
        await check("Replacement failure leaves last-good store and active configuration unchanged") {
            let store = RadialMenuStore(directory: try directory()), before = store.configuration
            let bytes = try Data(contentsOf: store.fileURL)
            try require(store.fileURL.path.withCString { chflags($0, UInt32(UF_IMMUTABLE)) } == 0, "Cannot induce owned replacement failure")
            defer { _ = store.fileURL.path.withCString { chflags($0, 0) } }
            store.draft = document()
            try require(!store.save() && store.configuration == before && (try Data(contentsOf: store.fileURL)) == bytes, "Failed replacement changed active or persisted data")
        }
        await check("One readback error after replacement resolves committed candidate and publishes it") {
            let reader = FaultReader(), f = try fixture(reader: reader)
            try f.openByRelease()
            let candidate = document(4); f.store.draft = candidate
            reader.failOnceAt = reader.calls + 2 // preflight succeeds, post-replacement read fails once.
            try require(f.store.save() && f.store.isReady && f.store.configuration == candidate,
                        "Readable committed candidate was mislabeled as uncommitted")
            try require(try RadialMenuCodec.decode(Data(contentsOf: f.store.fileURL)) == candidate,
                        "Committed resolution disagrees with the actual synthetic file")
            try require(!f.controller.isPresented && f.executed.isEmpty && f.events.isEmpty, "New committed configuration retained an old active menu")
            try f.openByRelease(); try require(f.controller.presentation?.totalCount == 4, "Resolved candidate was not available to the controller")
        }
        await check("Persistent readback failure keeps file pauses wheel and prevents reset from overwriting it") {
            let reader = FaultReader(), f = try fixture(reader: reader)
            let previous = f.store.configuration
            try f.openByRelease()
            let candidate = document(4); f.store.draft = candidate; reader.failFrom = reader.calls + 2
            try require(!f.store.save() && !f.store.isReady && f.store.configuration == previous && f.store.error != nil,
                        "Unknown commit was presented as a confirmed old or new configuration")
            let bytes = try Data(contentsOf: f.store.fileURL)
            try require(try RadialMenuCodec.decode(bytes) == candidate, "Unknown outcome discarded the actual committed file")
            try require(!f.controller.isPresented && !f.controller.hasPendingHold, "Unknown persistence state did not close the active wheel")
            f.controller.confirm(); f.tap()
            try require(f.executed.isEmpty && f.returnEvents.count == 2 && !f.controller.isPresented,
                        "Paused wheel executed an action or broke normal original Return")
            let calls = reader.calls
            f.store.resetDraft(); try require(f.store.error != nil && !f.store.save() && reader.calls == calls, "Reset cleared the unresolved-save block")
            try require(try Data(contentsOf: f.store.fileURL) == bytes, "Blocked save overwrote the unknown file")
            let reopened = RadialMenuStore(directory: f.store.fileURL.deletingLastPathComponent())
            try require(reopened.isReady && reopened.configuration == candidate, "An explicit fresh read could not resolve the actual committed candidate")
        }
        await check("A third valid readback document is uncertain rather than success or old-state rollback") {
            let reader = FaultReader(), f = try fixture(reader: reader), previous = f.store.configuration
            try f.openByRelease()
            let candidate = document(4), third = document(5, enabled: false)
            reader.third = try RadialMenuCodec.encode(third); reader.thirdFrom = reader.calls + 2
            f.store.draft = candidate
            try require(!f.store.save() && !f.store.isReady && f.store.configuration == previous && f.store.error != nil,
                        "Unexpected third document was incorrectly adopted or called uncommitted")
            try require(!f.controller.isPresented && f.executed.isEmpty, "Third-document uncertainty left wheel actions enabled")
            let bytes = try Data(contentsOf: f.store.fileURL)
            f.store.resetDraft(); try require(!f.store.save() && (try Data(contentsOf: f.store.fileURL)) == bytes,
                        "Uncertain third readback was overwritten by a later save")
        }
        await check("Short tap emits exactly one real Return pair via replay and never enters old macro forwarding") {
            let f = try fixture(); f.event("key.1", true); f.event("key.1", true, after: 0.02)
            try require(f.events.isEmpty, "Return was sent before short/long classification")
            f.event("key.1", false, after: 0.08); f.event("key.1", false)
            try require(f.returnEvents.count == 2 && f.returnEvents[0].type == .keyDown && f.returnEvents[1].type == .keyUp,
                        "Short tap did not create one Return down/up pair")
            try require(f.replays == [0] && f.middleForwards == 0 && f.executed.isEmpty && !f.controller.isPresented, "Short tap entered a macro or menu path")
        }
        await check("Late hold timer cannot reopen a completed short tap") {
            let f = try fixture(); f.tap(); f.time += 1
            try await Task.sleep(nanoseconds: 500_000_000)
            try require(f.returnEvents.count == 2 && !f.controller.isPresented && !f.controller.hasPendingHold && f.executed.isEmpty, "Old timer changed a completed short tap")
        }
        await check("Long release opens without Return and needs a separate short confirmation") {
            let f = try fixture(); try f.openByRelease()
            try require(f.returnEvents.isEmpty && f.middleForwards == 0 && f.executed.isEmpty, "Opening release executed or leaked Return")
            f.event("knob.right", true); f.event("knob.right", true); f.event("knob.left", true)
            let selected = f.store.configuration.items[1]
            try require(f.controller.presentation?.selectedItem.id == selected.id && f.scrollEvents.isEmpty, "Navigation leaked scrolling or selected wrong item")
            f.tap(); try await waitFor("one fake action", { !f.controller.executing })
            try require(f.executed == [selected.steps] && f.returnEvents.isEmpty && f.middleForwards == 0 && !f.controller.isPresented, "Confirmation dispatched incorrectly")
            f.event("key.1", false); f.controller.confirm(); try await Task.sleep(nanoseconds: 5_000_000)
            try require(f.executed.count == 1, "Duplicate release or confirm repeated the action")
        }
        await check("Real controller hold Task opens while held and opening up never confirms") {
            let f = try fixture(); f.event("key.1", true); f.time += 0.5
            try await waitFor("hold task", { f.controller.isPresented })
            try require(f.events.isEmpty && f.executed.isEmpty, "Hold Task produced a system action")
            f.event("key.1", false)
            try require(f.controller.isPresented && f.executed.isEmpty, "Opening up was reused as confirmation")
        }
        await check("Closed menu preserves raw rotary impulse direction and disabled middle forwarding") {
            let f = try fixture(enabled: false)
            for position: UInt8 in [4, 5] {
                for status: UInt8 in [0, 1] {
                    let trigger = HardwareTrigger.resolve(position: position, status: status)!
                    f.event(trigger.id, trigger.pressed)
                }
            }
            try require(f.scrollEvents.map { $0.getIntegerValueField(.scrollWheelEventDeltaAxis1) } == [-3, -3, 3, 3], "Closed rotary impulses changed")
            f.tap(); try require(f.returnEvents.count == 2 && f.replays.isEmpty && f.middleForwards == 1 && f.captures == 0, "Disabled wheel intercepted normal input")
        }
        await check("Page crossing and wrap keep stable item identity with no scroll leakage") {
            let f = try fixture(count: 10); try f.openByRelease()
            for _ in 0..<8 { f.event("knob.right", true) }
            try require(f.controller.presentation?.pageIndex == 1 && f.controller.presentation?.selectedItem.id == f.store.configuration.items[8].id, "Page crossing lost selection identity")
            for _ in 0..<2 { f.event("knob.right", true) }
            try require(f.controller.presentation?.selectedIndex == 0 && f.scrollEvents.isEmpty, "Global wrap leaked scroll or broke selection")
        }
        for reason in [RadialDismissReason.cancelled, .disconnected, .ownershipChanged, .windowClosed, .permissionChanged, .configurationChanged] {
            await check("Reset drains a pending middle without replay or late timer: \(reason.rawValue)") {
                let f = try fixture(); f.event("key.1", true); f.controller.cancel(reason: reason)
                f.event("key.1", true, after: 0.6); f.event("key.1", false)
                try require(f.events.isEmpty && !f.controller.isPresented && !f.controller.hasPendingHold && f.executed.isEmpty, "Cancelled pending gesture escaped")
                f.tap(); try require(f.returnEvents.count == 2 && f.replays.count == 1, "Controller did not rearm after release")
            }
        }
        await check("Target lost during pending releases cancelHold-only state and a fresh target can rearm") {
            let f = try fixture(); f.event("key.1", true); f.generation += 1; f.event("key.1", false, after: 0.1)
            try require(f.events.isEmpty && !f.controller.hasPendingHold, "Changed target received deferred Return")
            try f.openByRelease()
            try require(f.captures == 2 && f.controller.isPresented && f.executed.isEmpty, "Stale target permanently made the controller ineligible")
        }
        await check("Target change during open menu consumes the invalidating event instead of scroll or Return") {
            let f = try fixture(); try f.openByRelease(); f.generation += 1; f.event("knob.right", true)
            try require(!f.controller.isPresented && f.events.isEmpty && f.executed.isEmpty, "Focus change leaked the invalidating wheel event")
            try f.openByRelease(); f.event("key.1", true); f.generation += 1; f.event("key.1", false, after: 0.1)
            try require(!f.controller.isPresented && f.events.isEmpty && f.executed.isEmpty, "Focus change turned confirmation into Return")
        }
        await check("Busy transition and permission loss cancel menu without leaking the triggering event") {
            let f = try fixture(); try f.openByRelease(); f.busy = true; f.event("key.1", true); f.event("key.1", false, after: 0.1)
            try require(!f.controller.isPresented && f.events.isEmpty && f.executed.isEmpty, "Busy transition leaked confirmation")
            f.busy = false; try f.openByRelease(); f.authorized = false; f.event("knob.right", true)
            try require(!f.controller.isPresented && f.events.isEmpty && f.executed.isEmpty, "Permission loss leaked original action")
        }
        await check("Saved reconfiguration closes old presentation and drains confirmation") {
            let f = try fixture(); try f.openByRelease(); f.event("key.1", true)
            let old = f.store.configuration
            f.store.draft = document(4); try require(f.store.save(), "New configuration failed")
            f.event("key.1", false, after: 0.1)
            try require(!f.controller.isPresented && f.events.isEmpty && f.executed.isEmpty && f.store.configuration != old, "Old confirmation survived reconfiguration")
            try f.openByRelease(); try require(f.controller.presentation?.totalCount == 4, "New configuration was not adopted")
        }
        await check("Physical and AU05 modifiers keep original Return ownership") {
            let shifted = try fixture(); shifted.physicalFlags = CGEventFlags.maskShift.rawValue; shifted.tap()
            try require(shifted.returnEvents.count == 2 && shifted.returnEvents.allSatisfy { $0.flags.contains(.maskShift) } && shifted.replays.isEmpty, "Shift Return was changed into wheel interaction")
            let controlled = try fixture(); controlled.event("knob.press", true); controlled.tap(); controlled.event("knob.press", false)
            try require(controlled.returnEvents.count == 2 && controlled.returnEvents.allSatisfy { $0.flags.contains(.maskControl) } && !controlled.original.hasHeldModifier, "Owned AU05 Control or its up was lost")
        }
        await check("Knob opens immediately, consumes both clicks and rotation, then executes once") {
            let f=try fixture(count:9,activation:.knobPress)
            f.event("knob.press",true)
            try require(f.controller.isPresented && !f.controller.hasPendingHold && f.captures==1 && f.events.isEmpty,"First press was delayed, executed, or leaked Right Control")
            f.event("knob.press",false,after:0.1);f.event("knob.right",true,after:0.1)
            try require(f.controller.presentation?.selectedIndex==1 && f.scrollEvents.isEmpty,"Selection scrolled the target")
            f.event("knob.press",true,after:0.1);f.event("knob.press",true,after:0.1);f.event("knob.press",false,after:0.8)
            try await waitFor("knob action",{!f.controller.executing})
            try require(f.executed == [f.store.configuration.items[1].steps] && f.events.isEmpty && !f.controller.isPresented,"Confirmation dispatched wrong or duplicate action")
            f.tap();f.event("knob.right",true,after:0.1)
            try require(f.returnEvents.count==2 && f.scrollEvents.count==1,"Normal middle key or scroll changed outside wheel")
        }
        await check("Hardware knob preview changes selection and confirms without executing or sending keys") {
            let f=try fixture(enabled:false,count:9,activation:.knobPress)
            f.controller.showPreview();f.event("knob.right",true)
            try require(f.controller.previewMode && f.controller.presentation?.selectedIndex==1,"Hardware did not select in preview")
            f.event("knob.press",true,after:0.1);f.event("knob.press",true,after:0.1);f.event("knob.press",false,after:0.1)
            try require(!f.controller.isPresented && f.executed.isEmpty && f.captures==0 && f.events.isEmpty,"Preview reached a host action or target")
            f.controller.showPreview();f.event("key.2",true,after:0.1);f.event("key.2",false,after:0.1)
            try require(!f.controller.isPresented && f.events.isEmpty,"Preview cancel sent Backspace")
        }
        await check("Knob confirmation after focus loss executes nothing and releases no original key") {
            let f=try fixture(activation:.knobPress)
            f.event("knob.press",true);f.event("knob.press",false,after:0.1)
            f.event("knob.press",true,after:0.1);f.focusValid=false;f.event("knob.press",false,after:0.1)
            try require(!f.controller.isPresented && f.executed.isEmpty && f.events.isEmpty,"Invalid target confirmation escaped")
        }
        await check("All eight trigger modes use the actual controller without leaked keys or scroll") {
            for mode in RadialActivation.allCases {
                let f = try fixture(activation: mode)
                f.event(mode.triggerID, true, after: 0.1)
                f.event(mode.triggerID, false, after: mode.requiresHold ? 0.5 : 0.1)
                try require(f.controller.isPresented && f.events.isEmpty, "Configured controller trigger failed: " + mode.rawValue)
                f.event("knob.right", true, after: 0.1)
                f.event(mode.triggerID, true, after: 0.1); f.event(mode.triggerID, false, after: 0.1)
                try await waitFor("configured trigger action", { !f.executed.isEmpty })
                try require(f.executed.count == 1 && f.events.isEmpty && !f.controller.isPresented, "Configured controller trigger leaked input")
                if mode.requiresHold {
                    let short = try fixture(activation: mode)
                    short.event(mode.triggerID, true, after: 0.1); short.event(mode.triggerID, false, after: 0.1)
                    try require(!short.controller.isPresented && short.events.count == 2, "Configured short tap did not replay a pair")
                }
            }
        }
        await check("Preview selection and click confirmation execute nothing and capture no target") {
            let f = try fixture(enabled: false, count: 10); let bytes = try Data(contentsOf: f.store.fileURL)
            var changed = f.store.draft; changed.items[0].name = "未保存预览名称"; f.store.draft = changed
            f.controller.showPreview(); f.controller.select(8); f.controller.confirm()
            try require(f.executed.isEmpty && f.events.isEmpty && f.captures == 0 && !f.controller.isPresented,
                        "Preview reached action or real target capture")
            try require((try Data(contentsOf: f.store.fileURL)) == bytes && f.store.configuration.items[0].name != f.store.draft.items[0].name,
                        "Preview persisted its unsaved draft")
            f.controller.showPreview(); f.tap()
            try require(!f.controller.previewMode && f.executed.isEmpty && f.returnEvents.count == 2, "Hardware input executed preview or lost disabled normal Return")
        }
        await check("Diagram preview stays nonexecuting and stale preview click or close cannot affect a new live menu") {
            let f = try fixture(count: 10); f.controller.showPreview()
            let preview = f.controller.presentation!.session
            f.controller.chooseFromDiagram(session: preview, preview: true, index: 8)
            try require(f.controller.previewMode && f.controller.presentation?.selectedIndex == 8 && f.executed.isEmpty && f.captures == 0,
                        "Preview diagram selection executed or captured a real target")
            f.controller.chooseFromDiagram(session: preview, preview: false, index: 0)
            try require(f.controller.presentation?.selectedIndex == 8 && f.executed.isEmpty, "Wrong-mode callback altered a preview")
            f.controller.dismissFromDiagram(session: preview); try f.openByRelease()
            let live = f.controller.presentation!.session
            try require(live != preview, "New live menu reused preview identity")
            f.controller.chooseFromDiagram(session: preview, preview: true, index: 1)
            f.controller.dismissFromDiagram(session: preview)
            try require(f.controller.presentation?.session == live && f.controller.presentation?.selectedIndex == 0 && !f.controller.previewMode
                        && f.executed.isEmpty && f.events.isEmpty, "Stale preview callback selected, closed or executed the new live menu")
        }
        await check("Current live diagram click executes the global item once and stale click or close leaves the next menu intact") {
            let f = try fixture(count: 10); try f.openByRelease()
            for _ in 0..<8 { f.event("knob.right", true) }
            let first = f.controller.presentation!.session, selected = f.store.configuration.items[9]
            f.controller.chooseFromDiagram(session: first, preview: false, index: 9)
            try await waitFor("diagram action", { !f.controller.executing })
            f.controller.chooseFromDiagram(session: first, preview: false, index: 9)
            f.controller.dismissFromDiagram(session: first)
            try require(f.executed == [selected.steps] && f.events.isEmpty && f.middleForwards == 0, "Live diagram click dispatched the wrong or duplicate action")
            try f.openByRelease(); let next = f.controller.presentation!.session
            f.controller.chooseFromDiagram(session: first, preview: false, index: 0)
            f.controller.dismissFromDiagram(session: first)
            try require(next != first && f.controller.presentation?.session == next && f.controller.presentation?.selectedIndex == 0 && f.executed.count == 1,
                        "Old live callback affected the next menu")
        }
        await check("Illegal diagram index or mode cannot confirm the current live selection") {
            let f = try fixture(count: 10); try f.openByRelease()
            let session = f.controller.presentation!.session
            for index in [-1, 10, Int.max] { f.controller.chooseFromDiagram(session: session, preview: false, index: index) }
            f.controller.chooseFromDiagram(session: session, preview: true, index: 1)
            try require(f.controller.presentation?.session == session && f.controller.presentation?.selectedIndex == 0 && f.executed.isEmpty && f.events.isEmpty,
                        "Invalid click fell through into confirmation of another item")
        }
        await check("Diagram rechecks the selection session after target loss before confirming") {
            let f = try fixture(); try f.openByRelease()
            let session = f.controller.presentation!.session; f.generation += 1
            f.controller.chooseFromDiagram(session: session, preview: false, index: 1)
            try await Task.sleep(nanoseconds: 5_000_000)
            try require(!f.controller.isPresented && f.executed.isEmpty && f.events.isEmpty,
                        "Invalidated diagram selection still confirmed an action")
        }
        await check("Action failure produces no fallback Return and next tap works") {
            let f = try fixture(); f.actionFailure = true; try f.openByRelease(); f.tap()
            try await waitFor("failed fake action", { !f.controller.executing })
            try require(f.executed.count == 1 && f.events.isEmpty && !f.controller.isPresented, "Failed action replayed original input")
            f.tap(); try require(f.returnEvents.count == 2, "Failure left a stale target or blocked new short tap")
        }
        await check("Focus change before queued action execution prevents even fake action invocation") {
            let f = try fixture(); try f.openByRelease(); f.tap(); f.generation += 1
            try await waitFor("queued focus guard", { !f.controller.executing })
            try require(f.executed.isEmpty && f.events.isEmpty, "Action started after target changed before dispatch")
        }
        await check("Explicit cancellation before queued action execution cannot invoke the old action") {
            let f = try fixture(); try f.openByRelease(); f.tap(); f.controller.cancel(reason: .disconnected); f.connected = false
            try await waitFor("queued cancel guard", { !f.controller.executing })
            try require(f.executed.isEmpty && f.events.isEmpty, "Cancelled/disconnected queued action still executed")
        }
        await check("Cancelled in-flight fake action cannot publish a late success or replay Return") {
            let f = try fixture(), gate = ActionGate(); f.actionGate = gate
            try f.openByRelease(); f.tap()
            try await waitFor("held fake action", { f.executed.count == 1 })
            f.controller.cancel(reason: .configurationChanged)
            gate.release(); try await waitFor("cancelled action drain", { !f.controller.executing })
            try require(f.executed.count == 1 && f.events.isEmpty && f.controller.message?.hasPrefix("已执行：") != true,
                        "Cancelled action produced late success or duplicated original input")
            f.tap(); try require(f.returnEvents.count == 2, "Cancelled action did not allow a fresh normal short tap")
        }
        await check("Shutdown and late hold work remain inert") {
            let f = try fixture(); f.event("key.1", true); f.controller.shutdown(); f.time += 1
            f.event("key.1", false); f.event("knob.right", true)
            try await Task.sleep(nanoseconds: 500_000_000)
            try require(f.events.isEmpty && f.executed.isEmpty && !f.controller.isPresented, "Shutdown accepted a late event or timer")
        }
        fixtures.forEach { $0.stop() }
        try require(!rows.isEmpty, "No radial integration cases selected")
        let failed = rows.filter { $0["status"] as? String == "FAIL" }.count
        let receipt: [String: Any] = ["schemaVersion": 1, "status": failed == 0 ? "PASS" : "FAIL", "checks": rows.count,
            "passed": rows.count - failed, "failed": failed, "cases": rows,
            "actualRadialController": true, "actualOriginalCGEventFactory": true, "actualStore": true,
            "eventsPosted": 0, "HIDOpened": false, "GUIShown": false, "realUserDataRead": false,
            "AppDelegateWiring": "SOURCE_REVIEW_ONLY", "actualNativeOrStudioDuplication": "NOT_RUN", "physicalAU05Acceptance": "NOT_RUN"]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: report)
        print("Radial integration: \(rows.count-failed)/\(rows.count) PASS; no GUI/HID/events posted")
        for row in rows where row["status"] as? String == "FAIL" { print("FAIL \(row["name"] ?? ""): \(row["error"] ?? "")") }
        if failed > 0 { exit(1) }
    }
}
