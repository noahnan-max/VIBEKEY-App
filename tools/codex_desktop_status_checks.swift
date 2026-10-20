import Foundation
import VibekeyCore

private struct CheckFailure: Error { let message: String }
@main private struct CodexDesktopStatusChecks {
    static func main() throws {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--directory=") }) else { throw CheckFailure(message: "Private fixture root required") }
        let root = URL(fileURLWithPath: String(argument.dropFirst("--directory=".count)))
        guard root.path.contains("/.build/codex-desktop-status/"), root.lastPathComponent == "private-fixtures" else { throw CheckFailure(message: "Only isolated fixtures allowed") }
        let files = FileManager.default
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let origin = format.date(from: "2026-10-20T06:00:00.000Z")!
        var checks: [[String: Any]] = []
        func check(_ name: String, _ condition: Bool) { checks.append(["name": name, "pass": condition]) }
        func stamp(_ seconds: Double) -> String { format.string(from: origin.addingTimeInterval(seconds)) }
        func bytes(_ object: [String: Any], newline: Bool = true) throws -> Data {
            var value = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            if newline { value.append(10) }; return value
        }
        func header(_ session: String = "fixture-session", version: String = CodexDesktopSessionHeader.supportedVersion,
                    source: String = "vscode", originator: String = "Codex Desktop") throws -> Data {
            let payload: [String: Any] = ["id": session, "source": source, "originator": originator, "cli_version": version,
                "base_instructions": ["text": "PRIVATE_SENTINEL_BASE_INSTRUCTIONS"]]
            return try bytes(["type": "session_meta", "payload": payload])
        }
        func event(_ kind: String, _ second: Double, turn: String? = "fixture-turn-A", error: Bool = false, newline: Bool = true) throws -> Data {
            var payload: [String: Any] = ["type": kind, "last_agent_message": "PRIVATE_SENTINEL_ASSISTANT_MESSAGE",
                "item": ["arguments": "PRIVATE_SENTINEL_TOOL_ARGUMENTS", "text": "PRIVATE_SENTINEL_PROMPT"]]
            if let turn { payload["turn_id"] = turn }
            if error { payload["error"] = ["message": "PRIVATE_SENTINEL_ERROR_MESSAGE"] }
            return try bytes(["type": "event_msg", "timestamp": stamp(second), "payload": payload], newline: newline)
        }
        func write(_ data: Data, _ url: URL, mode: Int = 0o600) throws {
            try data.write(to: url); try files.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        func append(_ data: Data, _ url: URL) throws {
            let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        }
        struct Fixture {
            let sessions: URL; let bridge: URL; let rollout: URL; let base: String
            func reader() -> CodexDesktopStatusReader { .init(sessionsRoot: sessions, bridgeDirectory: bridge) }
        }
        func fixture(_ name: String, data: Data, epoch: Int? = 0) throws -> Fixture {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            let sessions = folder.appendingPathComponent("sessions", isDirectory: true)
            let bridge = folder.appendingPathComponent("bridge", isDirectory: true)
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: origin)
            let day = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!), isDirectory: true)
            try files.createDirectory(at: day, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.createDirectory(at: bridge, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let rollout = day.appendingPathComponent("rollout-fixture-session.jsonl")
            try write(data, rollout)
            let base = CodexDesktopStatusIdentity.digest("codex", "fixture-session", "")
            if let epoch {
                let row: [String: Any] = ["epoch": epoch, "latest": ["private": "PRIVATE_SENTINEL_BRIDGE_IGNORED"]]
                try write(try bytes(["schemaVersion": 1, "sessions": [base: row]]), bridge.appendingPathComponent("state.json"))
            }
            return Fixture(sessions: sessions, bridge: bridge, rollout: rollout, base: base)
        }
        func poll(_ reader: CodexDesktopStatusReader, _ seconds: Double) throws -> CodexDesktopStatusBatch {
            try reader.poll(at: origin.addingTimeInterval(seconds))
        }
        let initial = try header() + event("task_started", -10) + event("token_count", -1, turn: nil)
        do {
            let f = try fixture("real-shape", data: initial), reader = f.reader()
            let baseline = try poll(reader, 0)
            let active = baseline.events.first
            check("compatible current active metadata establishes running baseline", baseline.sourceAvailable && baseline.events.count == 1 && active?.state == .running && active?.endsTurn == false)
            check("session and turn identity match native bridge hashing", active?.sessionHash == CodexDesktopStatusIdentity.digest(f.base, "0") && active?.turnHash == CodexDesktopStatusIdentity.digest("codex", f.base, "fixture-turn-A"))
            let same = try poll(reader, 0.5)
            check("unchanged poll does not mint event ids or sequences", same.events == baseline.events)
            try append(event("item_completed", 1), f.rollout)
            let progress = try poll(reader, 1)
            check("same-turn progress refreshes running at original source time", progress.events.first?.state == .running && progress.events.first?.occurredAt == origin.addingTimeInterval(1).timeIntervalSince1970)
            try append(event("task_complete", 2), f.rollout)
            let end = try poll(reader, 2)
            check("new actual terminal is a correlated neutral turn end", end.events.first?.state == .turnCompleted && end.events.first?.endsTurn == true && end.events.first?.turnHash == active?.turnHash)
            check("terminal keeps source event time and expires at eight seconds", try poll(reader, 9.9).events == end.events && poll(reader, 10).events.isEmpty)
            let afterHint = try poll(reader, 11)
            check("terminal proof outlives light hint without replaying it", afterHint.events.isEmpty && afterHint.closedTurns == end.closedTurns && afterHint.closedTurns.count == 1 && afterHint.closedTurns.first?.occurredAt == origin.addingTimeInterval(2).timeIntervalSince1970)
            let encoded = String(data: try JSONEncoder().encode(end.events), encoding: .utf8)!
            check("normalized output never contains private ignored fields", !encoded.contains("PRIVATE_SENTINEL") && !encoded.contains("last_agent_message") && !encoded.contains("fixture-turn") && !encoded.contains("fixture-session"))
        }
        do {
            let f = try fixture("historical-terminal", data: initial + event("task_complete", -0.1)), reader = f.reader()
            let baseline = try poll(reader, 0)
            check("first scan never replays even a very recent old terminal", baseline.events.isEmpty)
            check("baseline terminal restores exact historical closure without a light hint", baseline.closedTurns.count == 1 && baseline.closedTurns.first?.sessionHash == CodexDesktopStatusIdentity.digest(f.base, "0") && baseline.closedTurns.first?.turnHash == CodexDesktopStatusIdentity.digest("codex", f.base, "fixture-turn-A") && baseline.closedTurns.first?.state == .turnCompleted)
            try append(event("task_started", 1, turn: "fixture-turn-B"), f.rollout)
            check("new turn after baseline is emitted", try poll(reader, 1).events.first?.state == .running)
            try append(event("task_complete", 2, turn: "fixture-turn-A"), f.rollout)
            check("old turn terminal cannot overwrite newer running turn", try poll(reader, 2).events.first?.state == .running)
        }
        do {
            let f = try fixture("failed-terminal", data: initial), reader = f.reader(); _ = try poll(reader, 0)
            try append(event("task_complete", 1, error: true), f.rollout)
            let failed = try poll(reader, 1)
            check("terminal error presence produces failed without decoding error text", failed.events.first?.state == .failed && failed.events.first?.endsTurn == true)
            check("failed terminal closure preserves failure meaning", failed.closedTurns.first?.state == .failed)
            try append(event("task_complete", 2), f.rollout)
            check("later neutral terminal cannot erase same-turn failed result", try poll(reader, 2).events == failed.events)
        }
        do {
            let f = try fixture("aborted-terminal", data: initial), reader = f.reader(); _ = try poll(reader, 0)
            try append(event("turn_aborted", 1), f.rollout)
            let aborted = try poll(reader, 1)
            try append(event("task_complete", 2), f.rollout)
            let after = try poll(reader, 2)
            check("aborted result remains interrupted and cannot become neutral completion", aborted.events.first?.state == .interrupted && aborted.events.first?.endsTurn == true && after.events == aborted.events)
            check("aborted terminal closure remains interrupted", after.closedTurns.first?.state == .interrupted)
        }
        do {
            let f = try fixture("partial-tail", data: initial), reader = f.reader(); let baseline = try poll(reader, 0)
            try append(event("task_complete", 1, newline: false), f.rollout)
            check("partial record never emits a terminal", try poll(reader, 1).events == baseline.events)
            try append(Data([10]), f.rollout)
            check("completed tail is decoded once after newline", try poll(reader, 1.5).events.first?.state == .turnCompleted)
        }
        do {
            let f = try fixture("initial-partial", data: initial + event("task_complete", -0.1, newline: false)), reader = f.reader()
            check("initial partial terminal keeps whole bootstrap unpresented", try poll(reader, 0).events.isEmpty)
            try append(Data([10]), f.rollout)
            check("finishing initial partial terminal does not replay it", try poll(reader, 1).events.isEmpty)
        }
        do {
            let f = try fixture("concurrent-future", data: initial), reader = f.reader(); let baseline = try poll(reader, 0)
            try append(event("task_complete", 1.1), f.rollout)
            let deferred = try poll(reader, 1)
            check("record arriving during poll is deferred without rejecting or publishing future time", deferred.sourceAvailable && deferred.events == baseline.events)
            check("deferred typed terminal is accepted when its source time arrives", try poll(reader, 1.2).events.first?.state == .turnCompleted)
        }
        do {
            let f = try fixture("future-bootstrap", data: initial + event("task_complete", 0.1)), reader = f.reader()
            check("future record during baseline cannot expose interim historical running", try poll(reader, 0).events.isEmpty)
            check("future baseline terminal is not replayed on next poll", try poll(reader, 1).events.isEmpty)
        }
        do {
            let f = try fixture("rotation", data: initial), reader = f.reader(); _ = try poll(reader, 0)
            let old = f.rollout.appendingPathExtension("saved"); try files.moveItem(at: f.rollout, to: old)
            try write(try header() + event("task_started", 1) + event("task_complete", 2), f.rollout)
            check("replacement inode establishes baseline without terminal replay", try poll(reader, 2).events.isEmpty)
            try write(try header(), f.rollout)
            check("file truncation discards old active and terminal state", try poll(reader, 3).events.isEmpty)
        }
        do {
            let f = try fixture("clock", data: initial), reader = f.reader(); _ = try poll(reader, 0)
            let rollback = try poll(reader, -1)
            check("clock rollback immediately withdraws source state", !rollback.sourceAvailable && rollback.events.isEmpty)
            try append(event("task_complete", 0.1), f.rollout)
            check("clock recovery baselines without replaying old terminal", try poll(reader, 1).events.isEmpty)
        }
        do {
            let f = try fixture("reconnect", data: initial), reader = f.reader(); _ = try poll(reader, 0)
            let moved = f.sessions.appendingPathExtension("offline"); try files.moveItem(at: f.sessions, to: moved)
            check("source disappearance withdraws metadata", try poll(reader, 1).events.isEmpty && !poll(reader, 1).sourceAvailable)
            try files.moveItem(at: moved, to: f.sessions)
            try append(event("task_complete", 2), f.rollout)
            check("reconnection never replays a terminal written while disconnected", try poll(reader, 2).events.isEmpty)
        }
        do {
            let f = try fixture("epochs", data: initial, epoch: nil), reader = f.reader()
            check("no invented epoch is emitted without private bridge identity", try poll(reader, 0).events.isEmpty)
            try write(try bytes(["schemaVersion": 1, "sessions": [f.base: ["epoch": 3]]]), f.bridge.appendingPathComponent("state.json"))
            check("late native epoch joins active metadata with exact native identity", try poll(reader, 1).events.first?.sessionHash == CodexDesktopStatusIdentity.digest(f.base, "3"))
            try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.bridge.appendingPathComponent("state.json").path)
            check("private bridge permission violation fails closed", try poll(reader, 2).events.isEmpty && !poll(reader, 2).sourceAvailable)
        }
        do {
            let f = try fixture("closure-late-epoch", data: initial + event("task_complete", -1), epoch: nil), reader = f.reader()
            let missing = try poll(reader, 0)
            check("historical terminal without native epoch cannot invent a proof identity", missing.closedTurns.isEmpty && missing.events.isEmpty)
            try write(try bytes(["schemaVersion": 1, "sessions": [f.base: ["epoch": 3]]]), f.bridge.appendingPathComponent("state.json"))
            let joined = try poll(reader, 1)
            check("late epoch restores only typed historical closure without completion hint", joined.closedTurns.count == 1 && joined.closedTurns.first?.sessionHash == CodexDesktopStatusIdentity.digest(f.base, "3") && joined.events.isEmpty)
        }
        do {
            let f = try fixture("closure-epoch-change", data: initial + event("task_complete", -1)), reader = f.reader()
            check("closure is initially bound to native epoch", try poll(reader, 0).closedTurns.count == 1)
            try write(try bytes(["schemaVersion": 1, "sessions": [f.base: ["epoch": 1]]]), f.bridge.appendingPathComponent("state.json"))
            check("changed epoch withdraws old proof rather than rehashing it", try poll(reader, 1).closedTurns.isEmpty)
            try append(event("task_started", 2, turn: "fixture-turn-B") + event("task_complete", 3, turn: "fixture-turn-B"), f.rollout)
            let current = try poll(reader, 3)
            check("new epoch requires new terminal evidence for its own turn", current.closedTurns.count == 1 && current.closedTurns.first?.sessionHash == CodexDesktopStatusIdentity.digest(f.base, "1") && current.closedTurns.first?.turnHash == CodexDesktopStatusIdentity.digest("codex", f.base, "fixture-turn-B"))
        }
        do {
            let f = try fixture("closure-corruption", data: initial + event("task_complete", -1)), reader = f.reader()
            _ = try poll(reader, 0)
            try append(Data("invalid-json\n".utf8), f.rollout)
            let corrupt = try poll(reader, 1)
            check("corrupt source withdraws every terminal proof", !corrupt.sourceAvailable && corrupt.closedTurns.isEmpty && corrupt.events.isEmpty)
        }
        do {
            var data = try header()
            for index in 0..<18 {
                data.append(try event("task_started", Double(-100 + index * 2), turn: "closed-turn-" + String(index)))
                data.append(try event("task_complete", Double(-99 + index * 2), turn: "closed-turn-" + String(index)))
            }
            let f = try fixture("closure-history-bound", data: data), result = try poll(f.reader(), 0)
            let hashes = Set(result.closedTurns.map(\.turnHash))
            check("historical closures retain distinct turns up to native pending capacity", result.events.isEmpty && result.closedTurns.count == 16 && hashes.contains(CodexDesktopStatusIdentity.digest("codex", f.base, "closed-turn-2")) && hashes.contains(CodexDesktopStatusIdentity.digest("codex", f.base, "closed-turn-17")) && !hashes.contains(CodexDesktopStatusIdentity.digest("codex", f.base, "closed-turn-0")))
        }
        for state: AgentSignalState in [.running, .taskCompleted] {
            let invalid = CodexDesktopTurnClosure(sessionHash: String(repeating: "a", count: 64), turnHash: String(repeating: "b", count: 64), occurredAt: origin.timeIntervalSince1970, state: state)
            do { try invalid.validate(); check("closure rejects nonterminal or business-success state " + state.rawValue, false) }
            catch { check("closure rejects nonterminal or business-success state " + state.rawValue, true) }
        }
        for (name, data) in [("version", try header(version: "future-version") + event("task_started", -1)),
                             ("originator", try header(originator: "Other Client") + event("task_started", -1)),
                             ("source", try header(source: "cli") + event("task_started", -1))] {
            let f = try fixture("unsupported-" + name, data: data)
            let result = try poll(f.reader(), 0)
            check("unsupported " + name + " produces no source or state", !result.sourceAvailable && result.events.isEmpty && result.closedTurns.isEmpty)
        }
        do {
            let f = try fixture("approval-transient", data: initial), reader = f.reader(); let baseline = try poll(reader, 0)
            try append(event("exec_approval_request", 1), f.rollout)
            try append(event("request_user_input", 1), f.rollout)
            check("rollout adapter never guesses approval or user input state", try poll(reader, 1).events == baseline.events)
        }
        do {
            let f = try fixture("unsafe-file", data: initial), reader = f.reader(); _ = try poll(reader, 0)
            try files.setAttributes([.posixPermissions: 0o666], ofItemAtPath: f.rollout.path)
            check("world-writable source clears prior state", try poll(reader, 1).events.isEmpty && !poll(reader, 1).sourceAvailable)
        }
        do {
            let f = try fixture("oversize", data: initial), reader = f.reader(); _ = try poll(reader, 0)
            try append(Data(repeating: 120, count: 2 * 1024 * 1024 + 1) + Data([10]), f.rollout)
            let result = try poll(reader, 1)
            check("oversized line is bounded and removes previous state", result.events.isEmpty && !result.sourceAvailable)
        }
        do {
            var data = try header() + event("task_started", -10)
            let body = try bytes(["type": "response_item", "payload": ["arguments": String(repeating: "PRIVATE_SENTINEL", count: 6500)]])
            for _ in 0..<55 { data.append(body) }
            data.append(try event("task_complete", -1))
            let f = try fixture("bounded-bootstrap", data: data), reader = f.reader()
            let first = try poll(reader, 0), second = try poll(reader, 1)
            check("bounded multibatch bootstrap cannot emit active or terminal history prematurely", first.events.isEmpty && second.events.isEmpty)
        }
        let failed = checks.filter { ($0["pass"] as? Bool) != true }
        let report: [String: Any] = ["status": failed.isEmpty ? "PASS" : "FAIL", "checks": checks,
            "total": checks.count, "failed": failed.count, "realCodexOrDeviceAcceptance": "NOT_RUN", "defaultSignalsWrites": 0]
        let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(data: output, encoding: .utf8)!)
        if !failed.isEmpty { exit(1) }
    }
}
