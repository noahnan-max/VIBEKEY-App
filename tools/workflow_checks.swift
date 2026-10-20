import Foundation
import VibekeyCore

private struct CheckFailure: LocalizedError {
    let label: String
    var errorDescription: String? { label }
}

private final class RunReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, Double)] = []

    func append(_ message: String) {
        lock.lock()
        entries.append((message, ProcessInfo.processInfo.systemUptime))
        lock.unlock()
    }

    var snapshot: [(String, Double)] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private final class StartedSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func signal() { finish(true) }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { self.finish(false) }
            }
        }
    }

    private func finish(_ value: Bool) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

@main
struct WorkflowChecks {
    static var checks = 0
    static var categories: [[String: Any]] = []

    static func main() async {
        var failure: String?
        do { try await runChecks() }
        catch let error as CheckFailure { failure = error.label }
        catch { failure = "验证异常（\((error as NSError).domain) \((error as NSError).code)）" }

        let status = failure == nil ? "PASS" : "FAIL"
        var evidence: [String: Any] = [
            "result": status,
            "checkedAtUTC": ISO8601DateFormatter().string(from: Date()),
            "clientDate": "2026-10-13",
            "checksPassed": checks,
            "categories": categories,
            "runtime": ProcessInfo.processInfo.operatingSystemVersionString,
            "buildContract": "Swift 5.8.1, MacOSX13.3 SDK, macOS 13 deployment target",
            "actionsExecuted": ["delay"],
            "hardwareWrites": 0,
            "permissionPrompts": 0,
            "notRun": ["CGEvent shortcut injection", "application launch", "URL open", "system Shortcuts execution", "CoreAudio volume/mute writes", "device-trigger integration"],
            "limitation": "取消会停止后续步骤；已交给系统或快捷指令的外部效果无法回滚。",
            "xctest": "NOT_RUN: local CLT lacks XCTest runtime; this standalone runner exercises production code."
        ]
        if let failure { evidence["failure"] = failure }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--evidence" {
            do {
                let url = URL(fileURLWithPath: CommandLine.arguments[2])
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            } catch {
                print("FAIL: could not write validation evidence.")
                exit(1)
            }
        } else if CommandLine.arguments.count != 1 {
            print("Usage: workflow-checks [--evidence /absolute/path.json]")
            exit(1)
        }
        print("\(status): \(checks) workflow checks in \(categories.count) categories. Only delay actions executed.")
        if let failure { print(failure); exit(1) }
    }

    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw CheckFailure(label: label) }
        checks += 1
    }

    static func rejects(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { checks += 1; return }
        throw CheckFailure(label: label)
    }

    static func category(_ name: String, _ body: () throws -> Void) throws {
        let before = checks
        do { try body(); categories.append(["name": name, "result": "PASS", "checks": checks - before]) }
        catch { categories.append(["name": name, "result": "FAIL", "checks": checks - before]); throw error }
    }

    static func asyncCategory(_ name: String, _ body: () async throws -> Void) async throws {
        let before = checks
        do { try await body(); categories.append(["name": name, "result": "PASS", "checks": checks - before]) }
        catch { categories.append(["name": name, "result": "FAIL", "checks": checks - before]); throw error }
    }

    static func binding(_ trigger: String, app: String = "") -> WorkflowBinding {
        WorkflowBinding(name: "Test", triggerID: trigger, applicationBundleID: app,
                        steps: [WorkflowStep(kind: .delay, seconds: 0)])
    }

    static func withFile(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vibekey-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("workflows.json"))
    }

    static func runChecks() async throws {
        try category("URL boundaries") {
            for text in ["file:///etc/passwd", "javascript:alert(1)", "shortcuts://run-shortcut?name=x", "https://",
                         "https://user:password@example.com", "https://example.com\n", "https://exa mple.com",
                         "https://exa%20mple.com", "https://example.com:65536"] {
                try check(WorkflowStep(kind: .openURL, argument: text).validationError != nil, "unsafe URL accepted")
            }
            try check(WorkflowStep(kind: .openURL, argument: "https://example.com?q=a%20b").validationError == nil, "valid URL rejected")
        }
        try category("Shortcut argv") {
            let literalName = "Focus; $(touch /tmp/should-not-exist) \"work\""
            try check(WorkflowValidation.shortcutArguments(for: literalName) == ["run", literalName], "shortcut name was split or interpreted")
            for name in ["", " ", "--help", "x\u{0}y", "name\nother"] {
                try rejects("invalid Shortcut argument accepted") { _ = try WorkflowValidation.shortcutArguments(for: name) }
            }
        }
        try category("Keyboard range and modifiers") {
            try check(WorkflowStep(keyCode: 128).validationError != nil, "bad key code accepted")
            try check(WorkflowStep(keyCode: .max).validationError != nil, "maximum key code accepted")
            try check(WorkflowStep(modifiers: 1).validationError != nil, "unknown modifier accepted")
            try check(WorkflowStep(keyCode: 36, modifiers: 0x00100000 | 0x00020000).validationError == nil, "valid accelerator rejected")
        }
        try category("Delay and total budget") {
            for seconds in [-1.0, 30.01, Double.infinity, Double.nan] {
                try check(WorkflowStep(kind: .delay, seconds: seconds).validationError != nil, "invalid delay accepted")
            }
            try rejects("delay budget exceeded") { try WorkflowValidation.validate((0..<5).map { _ in WorkflowStep(kind: .delay, seconds: 30) }) }
            try rejects("Shortcut budget exceeded") { try WorkflowValidation.validate((0..<7).map { _ in WorkflowStep(kind: .runShortcut, argument: "Focus") }) }
            try WorkflowValidation.validate([WorkflowStep(kind: .delay, seconds: 0), WorkflowStep(kind: .toggleMute)])
            checks += 1
        }
        try category("Whole macro preflight") {
            try rejects("later invalid step accepted") {
                try WorkflowValidation.validate([WorkflowStep(kind: .openApp, argument: "com.apple.TextEdit"),
                                                 WorkflowStep(kind: .openURL, argument: "file:///tmp/private")])
            }
        }
        try category("Step identity and count") {
            let duplicateStep = WorkflowStep(kind: .delay, seconds: 0)
            try rejects("duplicate step accepted") { try WorkflowValidation.validate([duplicateStep, duplicateStep]) }
            try rejects("step limit exceeded") { try WorkflowValidation.validate((0..<65).map { _ in WorkflowStep(kind: .delay, seconds: 0) }) }
            try rejects("empty macro accepted") { try WorkflowValidation.validate([WorkflowStep]()) }
        }
        try category("Application argument boundaries") {
            for text in ["Safari", "./Some.app", "/tmp/missing-\(UUID().uuidString).app", "com.apple.Safari --args", "com..apple"] {
                try check(WorkflowStep(kind: .openApp, argument: text).validationError != nil, "invalid app accepted")
            }
            try check(WorkflowStep(kind: .openApp, argument: "com.apple.Safari").validationError == nil, "bundle ID rejected")
        }
        try category("Context and binding identity") {
            let global = binding("key1"), app = binding("key1", app: "com.apple.Safari")
            try WorkflowValidation.validate([global, app]); checks += 1
            try rejects("duplicate global context accepted") { try WorkflowValidation.validate([global, binding("key1")]) }
            try rejects("duplicate app context accepted") { try WorkflowValidation.validate([app, binding("key1", app: "COM.APPLE.SAFARI")]) }
            var duplicate = binding("key2"); duplicate.id = global.id
            try rejects("duplicate binding identity accepted") { try WorkflowValidation.validate([global, duplicate]) }
            try rejects("invalid application context accepted") { try WorkflowValidation.validate([binding("key1", app: "Safari")]) }
        }
        try category("Persistence round trip and permissions") {
            try withFile { file in
                try check(WorkflowPersistence.load(from: file).isEmpty, "missing file did not load as empty")
                let bindings = [binding("key1"), binding("key1", app: "com.apple.Safari")]
                try WorkflowPersistence.save(bindings, to: file)
                try check(WorkflowPersistence.load(from: file) == bindings, "round trip mismatch")
                let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
                try check(mode?.intValue == 0o600, "configuration file is not private")
                try WorkflowPersistence.save([], to: file)
                try check(WorkflowPersistence.load(from: file).isEmpty, "empty configuration did not round trip")
            }
        }
        try category("Corrupt configuration preservation") {
            try withFile { file in
                let corrupt = Data("{broken".utf8)
                try corrupt.write(to: file)
                try rejects("corrupt load succeeded") { _ = try WorkflowPersistence.load(from: file) }
                try rejects("corrupt save succeeded") { try WorkflowPersistence.save([binding("key1")], to: file) }
                try check(Data(contentsOf: file) == corrupt, "corrupt original changed")
            }
        }
        try category("Future schema preservation") {
            try withFile { file in
                let future = Data("{\"schemaVersion\":2,\"bindings\":[]}".utf8)
                try future.write(to: file)
                try rejects("future version save succeeded") { try WorkflowPersistence.save([binding("key1")], to: file) }
                try check(Data(contentsOf: file) == future, "future schema original changed")
            }
        }
        try category("Invalid save preserves last good") {
            try withFile { file in
                let good = binding("key1")
                try WorkflowPersistence.save([good], to: file)
                let original = try Data(contentsOf: file)
                try rejects("invalid save succeeded") { try WorkflowPersistence.save([good, binding("key1")], to: file) }
                try check(Data(contentsOf: file) == original, "last good document changed")
            }
        }

        try await asyncCategory("Delay step order") {
            let receipt = RunReceipt()
            try await HostActions().run([WorkflowStep(kind: .delay, seconds: 0.02), WorkflowStep(kind: .delay, seconds: 0.03)]) { receipt.append($0) }
            let entries = receipt.snapshot
            let first = entries.first { $0.0.hasPrefix("步骤 1/") }
            let second = entries.first { $0.0.hasPrefix("步骤 2/") }
            let end = entries.first { $0.0 == "工作流步骤执行结束。" }
            try check(first != nil && second != nil && end != nil, "delay execution receipt incomplete")
            if let first, let second, let end {
                try check(second.1 - first.1 >= 0.019, "second delay started before first finished")
                try check(end.1 - second.1 >= 0.029, "macro ended before second delay finished")
            }
        }
        try await asyncCategory("Shared overlap protection") {
            let started = StartedSignal()
            let first = Task {
                try await HostActions().run([WorkflowStep(kind: .delay, seconds: 0.25)]) { message in
                    if message.hasPrefix("步骤 1/") { started.signal() }
                }
            }
            let didStart = await started.wait()
            if !didStart { first.cancel(); _ = await first.result; throw CheckFailure(label: "delay macro did not start") }
            var skipped = false
            do { try await HostActions().run([WorkflowStep(kind: .delay, seconds: 0)]) { _ in } }
            catch WorkflowError.alreadyRunning { skipped = true }
            catch { _ = await first.result; throw error }
            try await first.value
            try check(skipped, "two HostActions instances overlapped")
        }
        try await asyncCategory("Cancellation and gate cleanup") {
            let started = StartedSignal()
            let receipt = RunReceipt()
            let task = Task {
                try await HostActions().run([WorkflowStep(kind: .delay, seconds: 1), WorkflowStep(kind: .delay, seconds: 0)]) { message in
                    receipt.append(message)
                    if message.hasPrefix("步骤 1/") { started.signal() }
                }
            }
            let didStart = await started.wait()
            if !didStart { task.cancel(); _ = await task.result; throw CheckFailure(label: "cancel test macro did not start") }
            task.cancel()
            var canceled = false
            do { try await task.value } catch is CancellationError { canceled = true }
            try check(canceled, "cancellation did not return CancellationError")
            try check(!receipt.snapshot.contains { $0.0.hasPrefix("步骤 2/") }, "cancellation ran a later step")
            try await HostActions().run([WorkflowStep(kind: .delay, seconds: 0)]) { _ in }
            checks += 1
        }
    }
}
