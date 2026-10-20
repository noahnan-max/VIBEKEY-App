import Foundation
import VibekeyCore
import Combine

private struct CheckFailure: Error { let message: String }
private func hash(_ character: Character) -> String { String(repeating: String(character), count: 64) }
private func event(_ state: AgentSignalState, sequence: UInt64 = 1, at: Double = 100,
                   session: String = hash("a"), source: AgentSignalSource = .codex,
                   request: String? = nil, simulation: Bool = false) -> AgentSignal {
    .init(source: source, state: state, sessionHash: session, eventID: String(format: "%064llx", sequence),
          sequence: sequence, occurredAt: at, simulation: simulation, requestHash: request)
}
@MainActor private final class Publications {
    var total = 0
    var values: [String: Int] = [:]
    var subscriptions = Set<AnyCancellable>()
    init(_ store: AgentSignalStore) {
        store.objectWillChange.sink { [weak self] in self?.total += 1 }.store(in: &subscriptions)
        watch("snapshot", store.$snapshot)
        watch("physical", store.$physicalSnapshot)
        watch("sources", store.$sourceSnapshots)
        watch("events", store.$lastEvents)
        watch("proposed", store.$completionProposedCount)
        watch("error", store.$errorMessage)
        watch("simulation", store.$simulationTitle)
        watch("configured", store.$configuredSources)
    }
    private func watch<T>(_ name: String, _ publisher: Published<T>.Publisher) {
        publisher.dropFirst().sink { [weak self] _ in self?.values[name, default: 0] += 1 }.store(in: &subscriptions)
    }
}

@main private struct AgentSignalCacheChecks {
    @MainActor static func main() throws {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--directory=") }) else { throw CheckFailure(message: "Missing private fixture directory") }
        let base = URL(fileURLWithPath: String(argument.dropFirst("--directory=".count)))
        guard base.path.contains("/.build/ux-v36/cache/"), base.lastPathComponent == "private-fixtures" else { throw CheckFailure(message: "Only isolated private-fixtures supported") }
        let files = FileManager.default
        var checks: [[String: Any]] = []
        func check(_ name: String, _ condition: Bool) { checks.append(["name": name, "pass": condition]) }
        func fixture(_ name: String) throws -> URL {
            let root = base.appendingPathComponent(name, isDirectory: true)
            try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return root
        }
        func bytes(_ events: [AgentSignal], proposed: Int = 0) throws -> Data {
            let list = try JSONSerialization.jsonObject(with: JSONEncoder().encode(events))
            return try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "events": list, "completionProposedCount": proposed], options: .sortedKeys)
        }
        func write(_ data: Data, to root: URL, name: String = "inbox.json") throws {
            let path = root.appendingPathComponent(name)
            try data.write(to: path, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        do {
            do {
                let root = try fixture("unchanged")
                let data = try bytes([event(.turnCompleted)], proposed: 2); try write(data, to: root)
                var now = Date(timeIntervalSince1970: 100)
                let store = AgentSignalStore(directory: root, clock: { now }), publications = Publications(store)
                store.refresh()
                check("initial safe file parsed once", store.inboxDecodeCount == 1 && store.physicalSnapshot.state == .turnCompleted && store.completionProposedCount == 2)
                let initialCounts = publications.values, total = publications.total
                for tick in 1...70 { now = Date(timeIntervalSince1970: 100 + Double(tick) / 10); store.refresh() }
                check("same bytes skip all repeated decode", store.inboxDecodeCount == 1)
                check("same live state emits no duplicate property or object publication", publications.values == initialCounts && publications.total == total)
                let stamp = store.physicalSnapshot.lastEventAt
                now = Date(timeIntervalSince1970: 108); store.refresh()
                check("cached completion expires at original event time", store.physicalSnapshot.state == nil && store.physicalSnapshot.staleSessionCount == 1 && store.physicalSnapshot.lastEventAt == stamp && store.inboxDecodeCount == 1)
                check("TTL change publishes only presentation, not event list/count/error", publications.values["physical"] == (initialCounts["physical"] ?? 0) + 1 && publications.values["events"] == initialCounts["events"] && publications.values["proposed"] == initialCounts["proposed"] && publications.values["error"] == initialCounts["error"])
                let expired = publications.total
                for _ in 0..<10 { store.refresh() }
                check("stable expired metadata is not republished", publications.total == expired)
                try write(data, to: root); store.refresh()
                check("same bytes in a replacement inode do not refresh TTL or decode", store.inboxDecodeCount == 1 && store.physicalSnapshot.state == nil && publications.total == expired)
                var reencoded = data; reencoded.append(10); try write(reencoded, to: root); store.refresh()
                check("changed bytes reparse without publishing equal decoded state", store.inboxDecodeCount == 2 && publications.total == expired)
                now = Date(timeIntervalSince1970: 109)
                try write(bytes([event(.running, sequence: 2, at: 109)]), to: root); store.refresh()
                check("changed event updates real state exactly once", store.inboxDecodeCount == 3 && store.physicalSnapshot.state == .running && store.physicalSnapshot.selectedEventID == event(.running, sequence: 2).eventID && store.completionProposedCount == 0)
            }
            do {
                let root = try fixture("approval")
                try write(bytes([event(.approvalRequired, request: hash("b"))]), to: root)
                var now = Date(timeIntervalSince1970: 100)
                let store = AgentSignalStore(directory: root, clock: { now }); store.refresh()
                now = Date(timeIntervalSince1970: 399); store.refresh()
                check("cached approval remains within its original lifetime", store.physicalSnapshot.state == .approvalRequired && store.inboxDecodeCount == 1)
                now = Date(timeIntervalSince1970: 400); store.refresh()
                check("cached approval expires without artificial renewal", store.physicalSnapshot.state == nil && store.physicalSnapshot.unresolvedApprovalCount == 1 && store.physicalSnapshot.staleSessionCount == 1 && store.inboxDecodeCount == 1)
            }
            do {
                let root = try fixture("corruption"), good = try bytes([event(.running)], proposed: 4)
                try write(good, to: root)
                let store = AgentSignalStore(directory: root, clock: { Date(timeIntervalSince1970: 100) }), publications = Publications(store)
                store.refresh(); store.simulate(state: .turnCompleted)
                try write(Data("invalid json".utf8), to: root); store.refresh()
                check("bad replacement clears cached aggregation and visible old metadata", store.inboxDecodeCount == 2 && store.errorMessage != nil && store.physicalSnapshot == .unknown && store.snapshot == .unknown && store.lastEvents.isEmpty && store.sourceSnapshots.isEmpty && store.completionProposedCount == 0 && store.simulationTitle == nil)
                let count = publications.total, errors = publications.values["error"]
                store.refresh()
                check("repeated bad input revalidates but does not publish duplicate error/empty state", store.inboxDecodeCount == 3 && publications.total == count && publications.values["error"] == errors)
                store.simulate(state: .turnCompleted)
                check("error blocks synthetic green state", publications.total == count && store.snapshot == .unknown)
                try write(good, to: root); store.refresh()
                check("restoring formerly cached bytes must decode after error", store.inboxDecodeCount == 4 && store.errorMessage == nil && store.physicalSnapshot.state == .running && store.completionProposedCount == 4)
                check("error recovery publishes clear exactly once", publications.values["error"] == (errors ?? 0) + 1)
            }
            do {
                let root = try fixture("permissions"), good = try bytes([event(.running)])
                try write(good, to: root)
                let store = AgentSignalStore(directory: root, clock: { Date(timeIntervalSince1970: 100) })
                store.refresh(); let path = root.appendingPathComponent("inbox.json")
                try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path); store.refresh()
                check("same bytes with changed mode still fail security before cache", store.errorMessage != nil && store.inboxDecodeCount == 1 && store.physicalSnapshot == .unknown)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path); store.refresh()
                check("safe mode recovery redecodes cleared cache", store.errorMessage == nil && store.inboxDecodeCount == 2 && store.physicalSnapshot.state == .running)
                try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path); store.refresh()
                check("directory permissions checked on unchanged bytes", store.errorMessage != nil && store.inboxDecodeCount == 2)
                try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path); store.refresh()
                check("directory permission recovery remains usable", store.errorMessage == nil && store.inboxDecodeCount == 3)
                let alias = root.appendingPathComponent("same-inode.json"); try files.linkItem(at: path, to: alias); store.refresh()
                check("same-byte hardlink is checked every time", store.errorMessage != nil && store.inboxDecodeCount == 3)
                try files.removeItem(at: alias); store.refresh()
                check("hardlink removal permits fresh validation", store.errorMessage == nil && store.inboxDecodeCount == 4)
                try files.removeItem(at: path)
                let target = root.appendingPathComponent("private-target.json"); try good.write(to: target); try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                try files.createSymbolicLink(at: path, withDestinationURL: target); store.refresh()
                check("same-content symlink cannot hit cache", store.errorMessage != nil && store.inboxDecodeCount == 4)
                try files.removeItem(at: path); try write(good, to: root); store.refresh()
                check("symlink replacement by safe file recovers", store.errorMessage == nil && store.inboxDecodeCount == 5)
            }
            do {
                let root = try fixture("marker"), data = try bytes([event(.running)], proposed: 1)
                try write(data, to: root)
                let store = AgentSignalStore(directory: root, clock: { Date(timeIntervalSince1970: 100) }); store.refresh()
                let marker = root.appendingPathComponent("bridge-error.json"); try Data("{}".utf8).write(to: marker); store.refresh()
                check("new bridge failure marker defeats identical cached inbox", store.errorMessage != nil && store.inboxDecodeCount == 1 && store.lastEvents.isEmpty && store.completionProposedCount == 0)
                try files.removeItem(at: marker); store.refresh()
                check("marker recovery requires parsing again", store.errorMessage == nil && store.inboxDecodeCount == 2 && store.physicalSnapshot.state == .running)
            }
            do {
                let root = try fixture("removed"), data = try bytes([event(.running)])
                try write(data, to: root)
                let store = AgentSignalStore(directory: root, clock: { Date(timeIntervalSince1970: 100) }), publications = Publications(store)
                store.refresh(); try files.removeItem(at: root.appendingPathComponent("inbox.json")); store.refresh()
                check("file removal replaces cached real state with unknown", store.errorMessage == nil && store.physicalSnapshot == .unknown && store.lastEvents.isEmpty && store.inboxDecodeCount == 1)
                let count = publications.total; store.refresh(); store.refresh()
                check("repeated missing file does not publish", publications.total == count && store.inboxDecodeCount == 1)
                try write(data, to: root); store.refresh()
                check("missing-to-existing transition redecodes same prior bytes", store.inboxDecodeCount == 2 && store.physicalSnapshot.state == .running)
            }
            do {
                let root = try fixture("stop"), data = try bytes([event(.running)], proposed: 3)
                try write(data, to: root)
                let store = AgentSignalStore(directory: root, clock: { Date(timeIntervalSince1970: 100) }), publications = Publications(store)
                store.start(); store.simulate(state: .turnCompleted); store.stop()
                check("stop clears cache, event metadata and simulation", store.snapshot == .unknown && store.physicalSnapshot == .unknown && store.lastEvents.isEmpty && store.sourceSnapshots.isEmpty && store.completionProposedCount == 0 && store.simulationTitle == nil && store.errorMessage == nil)
                let count = publications.total
                store.stop(); RunLoop.main.run(until: Date().addingTimeInterval(1.1))
                check("repeat stop and obsolete timer do not publish or reparse", publications.total == count && store.inboxDecodeCount == 1)
                store.start()
                check("restart parses unchanged file after stop", store.inboxDecodeCount == 2 && store.physicalSnapshot.state == .running && store.completionProposedCount == 3)
                store.stop()
                try write(Data("bad".utf8), to: root); store.refresh(); store.stop()
                check("stop clears an error and remains recoverable", store.errorMessage == nil && store.snapshot == .unknown)
                try write(data, to: root); store.refresh()
                check("safe bytes recover after error then stop", store.inboxDecodeCount == 4 && store.physicalSnapshot.state == .running)
            }
            do {
                let root = try fixture("simulation")
                var now = Date(timeIntervalSince1970: 100)
                let store = AgentSignalStore(directory: root, clock: { now }), publications = Publications(store)
                store.refresh(); let real = store.physicalSnapshot, source = store.sourceSnapshots, records = store.lastEvents
                store.simulate(state: .turnCompleted)
                check("simulation remains separate from physical cache", store.snapshot.isSimulation && store.physicalSnapshot == real && store.sourceSnapshots == source && store.lastEvents == records && store.inboxDecodeCount == 0)
                let count = publications.total
                now = Date(timeIntervalSince1970: 107); store.refresh(); store.refresh()
                check("unchanged missing cache does not extend or republish live demo", store.snapshot.isSimulation && publications.total == count)
                now = Date(timeIntervalSince1970: 108); store.refresh()
                check("demo expires with cache hit and never becomes real", !store.snapshot.isSimulation && store.snapshot.state == nil && store.simulationTitle == nil && store.physicalSnapshot == real)
                try write(bytes([event(.approvalRequired, at: 108, request: hash("b"))]), to: root); store.refresh()
                let physical = store.physicalSnapshot; store.simulate(state: .turnCompleted); store.refresh()
                check("real approval cannot be hidden by cached demo", store.physicalSnapshot == physical && store.snapshot == physical && !store.snapshot.isSimulation && store.inboxDecodeCount == 1)
            }
            do {
                let root = try fixture("time-boundaries")
                try write(bytes([event(.running, at: 101)]), to: root)
                var now = Date(timeIntervalSince1970: 100)
                let store = AgentSignalStore(directory: root, clock: { now }); store.refresh()
                check("future event remains rejected on initial decode", store.physicalSnapshot.state == nil && store.lastEvents.isEmpty && store.inboxDecodeCount == 1)
                now = Date(timeIntervalSince1970: 101); store.refresh()
                check("temporarily ineligible future batch is not frozen by cache", store.physicalSnapshot.state == .running && store.physicalSnapshot.lastEventAt == now && store.inboxDecodeCount == 2)
                now = Date(timeIntervalSince1970: 102); store.refresh()
                check("eligible batch uses cache on normal forward clock", store.inboxDecodeCount == 2)
                now = Date(timeIntervalSince1970: 99); store.refresh()
                check("clock rollback rejects same batch without making future green", store.inboxDecodeCount == 2 && store.physicalSnapshot.state == nil && store.lastEvents.isEmpty && store.errorMessage != nil)
            }
            do {
                let root = try fixture("clock-rollback")
                let data = try bytes([event(.turnCompleted)])
                try write(data, to: root)
                var now = Date(timeIntervalSince1970: 100)
                let store = AgentSignalStore(directory: root, clock: { now }), publications = Publications(store)
                store.refresh(); now = Date(timeIntervalSince1970: 120); store.refresh()
                check("completion expired before rollback negative case", store.physicalSnapshot.state == nil && store.inboxDecodeCount == 1)
                now = Date(timeIntervalSince1970: 107); store.refresh()
                check("rollback after cache-hit expiry never relights same event", store.physicalSnapshot == .unknown && store.lastEvents.isEmpty && store.errorMessage != nil && store.inboxDecodeCount == 1)
                let count = publications.total
                now = Date(timeIntervalSince1970: 130); store.refresh(); store.refresh()
                check("same rejected batch stays unknown even when clock catches up", store.physicalSnapshot == .unknown && store.errorMessage != nil && store.inboxDecodeCount == 1 && publications.total == count)
                now = Date(timeIntervalSince1970: 131)
                try write(bytes([event(.running, sequence: 2, at: 131)]), to: root); store.refresh()
                check("new safe batch recovers from rollback without rewriting event time", store.errorMessage == nil && store.physicalSnapshot.state == .running && store.physicalSnapshot.lastEventAt == now && store.inboxDecodeCount == 2)
            }
            do {
                let root = try fixture("stop-proposed")
                try write(bytes([event(.stopProposed)]), to: root)
                var now = Date(timeIntervalSince1970: 100)
                let store = AgentSignalStore(directory: root, clock: { now }); store.refresh()
                check("new stop proposal is retained as pending, not completed", store.physicalSnapshot.state == .stopProposed && store.physicalSnapshot.state != .turnCompleted && store.inboxDecodeCount == 1)
                now = Date(timeIntervalSince1970: 108); store.refresh()
                check("cached stop proposal expires after eight seconds without inferring completion", store.physicalSnapshot.state == nil && store.inboxDecodeCount == 1)
            }
            do {
                let root = try fixture("setup-only")
                let setup = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "sources": ["codex", "claude", "codex"], "installedAt": 10.0] as [String: Any], options: .sortedKeys)
                try write(setup, to: root, name: "setup.json")
                let store = AgentSignalStore(directory: root, clock: { Date(timeIntervalSince1970: 100) }), publications = Publications(store)
                store.refresh()
                check("safe installation receipt deduplicates known configured sources", store.configuredSources == [.codex, .claude] && store.setupDecodeCount == 1)
                check("installation receipt alone never establishes a real Agent state", store.physicalSnapshot == .unknown && store.snapshot == .unknown && store.lastEvents.isEmpty && store.sourceSnapshots.values.allSatisfy { $0.state == nil } && store.inboxDecodeCount == 0)
                let count = publications.total
                for _ in 0..<20 { store.refresh() }
                check("unchanged setup cache avoids decode and publication", store.setupDecodeCount == 1 && publications.total == count)
                store.stop(); check("stop clears historical configuration and its cache", store.configuredSources.isEmpty)
                store.refresh(); check("setup redecodes after stop", store.setupDecodeCount == 2 && store.configuredSources == [.codex, .claude] && store.physicalSnapshot == .unknown)
                try files.removeItem(at: root.appendingPathComponent("setup.json")); store.refresh()
                check("missing setup receipt clears configured sources only", store.configuredSources.isEmpty && store.errorMessage == nil && store.physicalSnapshot == .unknown)
            }
            do {
                let root = try fixture("setup-independent")
                try write(bytes([event(.running)]), to: root)
                let setup = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "sources": ["codex"], "installedAt": 10.0] as [String: Any], options: .sortedKeys)
                try write(setup, to: root, name: "setup.json")
                let store = AgentSignalStore(directory: root, clock: { Date(timeIntervalSince1970: 100) }), publications = Publications(store)
                store.refresh(); let real = store.physicalSnapshot
                let invalid: [[String: Any]] = [
                    ["schemaVersion": 2, "sources": ["codex"], "installedAt": 10],
                    ["schemaVersion": 1, "sources": ["unknown-agent"], "installedAt": 10],
                    ["schemaVersion": 1, "sources": ["codex"], "installedAt": 0],
                    ["schemaVersion": 1, "sources": ["codex"], "installedAt": -1],
                    ["schemaVersion": 1, "sources": ["codex"]],
                    ["schemaVersion": 1, "sources": ["codex"], "installedAt": 10, "path": "synthetic-disallowed-field"]
                ]
                for (index, object) in invalid.enumerated() {
                    try write(JSONSerialization.data(withJSONObject: object, options: .sortedKeys), to: root, name: "setup.json"); store.refresh()
                    check("invalid setup \(index) cannot affect valid cached event", store.configuredSources.isEmpty && store.errorMessage == nil && store.physicalSnapshot == real && store.inboxDecodeCount == 1)
                }
                try write(Data("{\"schemaVersion\":1,\"sources\":[\"codex\"],\"installedAt\":1e309}".utf8), to: root, name: "setup.json"); store.refresh()
                check("nonfinite setup time cannot establish configuration", store.configuredSources.isEmpty && store.physicalSnapshot == real && store.errorMessage == nil)
                let unchanged = publications.values
                store.refresh()
                check("repeated bad setup does not republish unrelated Agent state", publications.values == unchanged && store.inboxDecodeCount == 1)
                try write(setup, to: root, name: "setup.json"); store.refresh()
                check("safe setup recovery leaves event decode cached", store.configuredSources == [.codex] && store.physicalSnapshot == real && store.inboxDecodeCount == 1)
                let path = root.appendingPathComponent("setup.json")
                let setupDecodes = store.setupDecodeCount
                try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path); store.refresh()
                check("unchanged setup bytes still require safe file mode", store.configuredSources.isEmpty && store.setupDecodeCount == setupDecodes && store.physicalSnapshot == real && store.errorMessage == nil)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path); store.refresh()
                check("setup mode recovery revalidates cache independently", store.configuredSources == [.codex] && store.setupDecodeCount == setupDecodes + 1 && store.inboxDecodeCount == 1)
                try files.removeItem(at: path)
                let target = root.appendingPathComponent("private-setup-target.json"); try setup.write(to: target); try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                try files.createSymbolicLink(at: path, withDestinationURL: target); store.refresh()
                check("setup symlink cannot reuse safe cached bytes", store.configuredSources.isEmpty && store.physicalSnapshot == real && store.errorMessage == nil)
                try files.removeItem(at: path); try write(setup, to: root, name: "setup.json"); store.refresh()
                try write(Data("bad inbox".utf8), to: root); store.refresh()
                check("event error does not present historical installation as runtime success", store.configuredSources == [.codex] && store.errorMessage != nil && store.physicalSnapshot == .unknown && store.lastEvents.isEmpty)
            }
            do {
                let root = try fixture("limits"), data = try bytes([event(.running)])
                try write(data, to: root)
                let store = AgentSignalStore(directory: root, clock: { Date(timeIntervalSince1970: 100) }); store.refresh()
                try write(Data(repeating: 32, count: 2 * 1024 * 1024 + 1), to: root); store.refresh()
                check("oversized replacement rejected before decode/cache", store.errorMessage != nil && store.inboxDecodeCount == 1 && store.physicalSnapshot == .unknown)
                try write(bytes([event(.running, simulation: true)]), to: root); store.refresh()
                check("simulation flag in real inbox still rejected", store.errorMessage != nil && store.physicalSnapshot == .unknown && store.inboxDecodeCount == 2)
                try write(data, to: root); store.refresh()
                check("safe recovery after oversize and rejected inbox does not reuse stale graph", store.errorMessage == nil && store.inboxDecodeCount == 3 && store.physicalSnapshot.state == .running)
            }
        } catch { check("unexpected fixture error: \(error)", false) }
        let failed = checks.filter { $0["pass"] as? Bool == false }.count
        let receipt: [String: Any] = ["status": failed == 0 ? "PASS" : "FAIL", "checkCount": checks.count, "failed": failed,
            "checks": checks, "privateSyntheticInboxOnly": true, "realHookConfigurationWritten": false,
            "realTasksObserved": false, "HIDOpened": false, "GUIShown": false, "networkCalled": false]
        print(String(decoding: try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        if failed > 0 { exit(1) }
    }
}
