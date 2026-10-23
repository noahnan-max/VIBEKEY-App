import AppKit
import VibekeyCore

@main @MainActor struct PassiveStatisticsChecks {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ label: String) {
        checks += 1; if !value() { fatalError("FAIL: " + label) }
    }
    static func pair(_ original: String, _ range: NSRange, _ inserted: String) -> (InputFieldSnapshot, InputFieldSnapshot) {
        let after = (original as NSString).replacingCharacters(in: range, with: inserted)
        return (.init(text: original, selection: range), .init(text: after, selection: NSRange(location: range.location + inserted.utf16.count, length: 0)))
    }
    static func rejects(_ before: InputFieldSnapshot, _ after: InputFieldSnapshot, _ expected: InputObservationFailure) {
        do { _ = try ObservedInputCharacters.count(before: before, after: after); expect(false, "invalid observation accepted") }
        catch { expect(error as? InputObservationFailure == expected, "correct rejection reason") }
    }
    static func main() async throws {
        expect(!UsageStatisticsPreferences().collectionEnabled, "new public users must explicitly opt in before observation")
        expect(AutomaticMicrophoneMonitor.matches(name: "AU05", manufacturer: "AU05", inputStreams: 1, outputStreams: 0), "AU05 input-only microphone identified")
        expect(AutomaticMicrophoneMonitor.matches(name: "VIBEKEY Microphone", manufacturer: "Vijim", inputStreams: 1, outputStreams: 0), "VIBEKEY name identified without choosing a key")
        expect(!AutomaticMicrophoneMonitor.matches(name: "AU050", manufacturer: "Other", inputStreams: 1, outputStreams: 0), "similar unrelated model rejected")
        expect(!AutomaticMicrophoneMonitor.matches(name: "AU05 Speakers", manufacturer: "AU05", inputStreams: 0, outputStreams: 1), "speaker playback cannot start input statistics")
        expect(!AutomaticMicrophoneMonitor.matches(name: "AU05 Duplex", manufacturer: "AU05", inputStreams: 1, outputStreams: 1), "ambiguous duplex activity cannot become recording")
        expect(!AutomaticMicrophoneMonitor.matches(name: "Mac microphone", manufacturer: "Apple", inputStreams: 1, outputStreams: 0), "unrelated microphone rejected")
        for (original, range, inserted, count) in [
            ("前缀：后缀", NSRange(location: 3, length: 0), "明天开会", 4),
            ("前缀：旧标题后缀", NSRange(location: 3, length: 3), "新标题", 3),
            ("前缀：一段原本很长的文字后缀", NSRange(location: 3, length: 9), "短句", 2),
            ("AB", NSRange(location: 1, length: 0), "你 好\n😀", 3),
            ("AB", NSRange(location: 1, length: 0), "👨‍👩‍👧‍👦e\u{301}中", 3),
            ("", NSRange(location: 0, length: 0), "hello world", 10),
            ("AB", NSRange(location: 1, length: 0), "  \n", 0)
        ] {
            let p = pair(original, range, inserted)
            expect((try? ObservedInputCharacters.count(before: p.0, after: p.1)) == count, "insert/replacement Unicode characters")
        }
        let p = pair("AB", .init(location: 1, length: 0), "测试")
        var received = ReceivedInputCharacters(before: p.0)
        func draft(_ text: String) -> InputFieldSnapshot { pair("AB", .init(location: 1, length: 0), text).1 }
        expect((try? received.receive(draft("草稿"))) == 2, "received input counted immediately")
        expect((try? received.receive(draft("最终文字"))) == 4, "whole draft rewrite only adds new growth")
        expect((try? received.receive(draft("最终文字"))) == 4, "repeated draft cannot duplicate count")
        expect((try? received.receive(draft("最终"))) == 4, "later shortening never subtracts received input")
        expect((try? received.receive(draft("最终新输入"))) == 7, "new insertion after deletion still counts")
        expect((try? received.receive(.init(text: "", selection: .init(location: 0, length: 0)))) == 7, "submit or clear preserves received amount")
        expect((try? received.receive(.init(text: "再说一次", selection: .init(location: 4, length: 0), composing: true))) == 11, "next phrase and marked text count without final correction")
        expect((try? received.receive(.init(text: "其他文字", selection: .init(location: 4, length: 0)))) == 11, "same-length post-edit does not recount an entire draft")
        expect((try? ObservedInputCharacters.count(before: p.0, after: .init(text: p.1.text, selection: .init(location: 0, length: 0), selectionKnown: false))) == 2, "text-only editor with known starting selection counted")
        expect((try? ObservedInputCharacters.count(before: .init(text: "AB", selection: .init(location: 0, length: 0), selectionKnown: false), after: .init(text: "A你 好😀B", selection: .init(location: 0, length: 0), selectionKnown: false))) == 3, "text-only web editor final Unicode delta counted")
        rejects(p.0, .init(text: p.1.text, selection: p.1.selection, composing: true), .composing)
        rejects(p.0, p.0, .unchanged)
        rejects(p.0, .init(text: "XB", selection: .init(location: 1, length: 0)), .changedContext)
        rejects(p.0, .init(text: p.1.text, selection: .init(location: 0, length: 0)), .invalidRange)
        rejects(.init(text: "😀", selection: .init(location: 1, length: 0)), p.1, .invalidRange)
        rejects(.init(text: "AB", selection: .init(location: Int.max, length: Int.max)), p.1, .invalidRange)
        rejects(.init(text: "AB", selection: .init(location: NSNotFound, length: 0)), p.1, .invalidRange)
        rejects(.init(text: String(repeating: "字", count: 50_001), selection: .init(location: 0, length: 0)), p.1, .invalidRange)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vibekey-usage-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        var ledger = UsageStatisticsLedger(); ledger.preferences.enabled = true; let now = Date(); ledger.startedAt = now
        ledger.record(at: now, seconds: 10, characters: 30, source: .observed)
        ledger.record(at: now, seconds: 20, characters: 60, source: .estimated)
        ledger.record(at: now, seconds: 3, characters: nil, source: .unavailable)
        expect(ledger.totals.countedOperationSeconds == 30 && ledger.totals.operationSeconds == 33, "missing counts do not become zero-character savings")
        expect(ledger.totals.totalCharacters == 90 && ledger.totals.sessions == 3, "sources remain separate and sum once")
        ledger.record(at: now, seconds: .nan, characters: 999, source: .observed)
        expect(ledger.totals.totalCharacters == 90, "invalid duration rejected")
        try UsageStatisticsFile.save(ledger, directory: folder)
        expect((try? UsageStatisticsFile.load(directory: folder)) == ledger, "aggregate roundtrip")
        let path = folder.appendingPathComponent("usage.json"), bytes = try Data(contentsOf: path)
        let json = String(decoding: bytes, as: UTF8.self)
        var legacy = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        var legacyPreferences = legacy["preferences"] as! [String: Any]
        legacyPreferences["triggerID"] = "key.2"; legacyPreferences["mode"] = "toggle"
        legacy["preferences"] = legacyPreferences
        let migrated = try JSONDecoder().decode(UsageStatisticsLedger.self, from: JSONSerialization.data(withJSONObject: legacy))
        expect(migrated.days == ledger.days && migrated.preferences.enabled, "legacy upper/lower key and hold/toggle settings no longer constrain aggregate data")
        var disabled = ledger; disabled.preferences.enabled = false
        let paused = try JSONDecoder().decode(UsageStatisticsLedger.self, from: JSONEncoder().encode(disabled))
        expect(!paused.preferences.enabled, "explicit pause remains respected")
        expect(!json.contains("测试") && !json.contains("text\"") && !json.contains("selection"), "no input text or caret persisted")
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private file permissions")
        try Data("{broken".utf8).write(to: path)
        do { _ = try UsageStatisticsFile.load(directory: folder); expect(false, "corruption accepted") } catch { expect(true, "corruption rejected") }
        expect((try? Data(contentsOf: path)) == Data("{broken".utf8), "corrupt file preserved")
        try bytes.write(to: path)
        let linkFolder = folder.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkFolder, withDestinationURL: folder)
        do { _ = try UsageStatisticsFile.load(directory: linkFolder); expect(false, "symlink accepted") } catch { expect(true, "symlink rejected") }
        var streaks = UsageStatisticsLedger()
        for n in [0, 1, 2, 4] { streaks.record(at: Calendar.current.date(byAdding: .day, value: -n, to: now)!, seconds: 1, characters: 3, source: .observed) }
        expect(streaks.streaks(now: now).current == 3 && streaks.streaks(now: now).longest == 3, "missing day breaks streak")

        var receipts: [PassiveInputObserver.Receipt] = []
        var reads = 0
        let before = InputFieldSnapshot(text: "AB", selection: .init(location: 1, length: 0))
        let observer = PassiveInputObserver(settleSeconds: 3, readerFactory: { _ in
            .init(before: before, read: {
                reads += 1; let word = reads == 1 ? "草稿" : "最终文字"
                return pair("AB", .init(location: 1, length: 0), word).1
            })
        }, completed: { receipts.append($0) })
        let id = UUID(), uptime = ProcessInfo.processInfo.systemUptime
        observer.begin(id: id, at: now, uptime: uptime - 3, pid: 123)
        observer.end(id: id, uptime: uptime)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while receipts.isEmpty && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        expect(receipts.count == 1 && receipts[0].characters == 4, "streaming drafts not accumulated")
        observer.end(id: id, uptime: uptime); try await Task.sleep(nanoseconds: 300_000_000)
        expect(receipts.count == 1, "duplicate end does not duplicate count")
        var slowCompleted = false
        let slow = PassiveInputObserver(readerFactory: { _ in Thread.sleep(forTimeInterval: 0.4); throw InputObservationFailure.timeout }, completed: { _ in slowCompleted = true })
        let tick = ProcessInfo.processInfo.systemUptime, slowID = UUID()
        slow.begin(id: slowID, at: now, uptime: tick - 1, pid: 123); slow.end(id: slowID, uptime: tick)
        expect(ProcessInfo.processInfo.systemUptime - tick < 0.03, "slow AX worker cannot block caller")
        try await Task.sleep(nanoseconds: 100_000_000)
        expect(!slowCompleted, "main actor responsive while worker is blocked")
        try await Task.sleep(nanoseconds: 500_000_000); expect(slowCompleted, "timeout produces bounded failure")
        let store = UsageStatisticsStore(directory: folder.appendingPathComponent("fixture"), permitsObservation: false)
        store.setCollectionEnabled(true); store.handle("key.0", pressed: true, pid: 123)
        store.microphoneChanged(.active, pid: 123)
        expect(!store.isObserving, "display probes cannot observe external input")
        await store.flush()

        var automaticText = "AB", automaticFactoryCalls = 0
        let automatic = UsageStatisticsStore(directory: folder.appendingPathComponent("automatic"), observeHardware: false, readerFactory: { _ in
            automaticFactoryCalls += 1
            return .init(before: before, read: { .init(text: automaticText, selection: .init(location: automaticText.utf16.count - 1, length: 0)) })
        })
        automatic.setCollectionEnabled(true)
        for key in ["key.0", "key.1", "key.2", "knob.press"] {
            automatic.handle(key, pressed: true, pid: 123); automatic.handle(key, pressed: false, pid: 123)
        }
        expect(!automatic.isObserving && automatic.ledger.totals.sessions == 0, "all keys may prime but no key or hold/release starts a statistic")
        automatic.microphoneChanged(.active, pid: 123); automatic.microphoneChanged(.active, pid: 123)
        expect(automatic.isObserving, "actual microphone activity starts automatically")
        try await Task.sleep(nanoseconds: 400_000_000)
        automaticText = "A最终文字B"
        try await Task.sleep(nanoseconds: 600_000_000)
        expect(automatic.displayLedger.totals.observedCharacters == 4 && automatic.ledger.totals.sessions == 0 && automatic.liveSummary != nil, "live input visible before microphone stop and without premature persistence")
        automaticText = "A终B"
        try await Task.sleep(nanoseconds: 300_000_000)
        expect(automatic.displayLedger.totals.observedCharacters == 4, "live total never retracts after input method shortening")
        automatic.handle("key.2", pressed: true, pid: 123); automatic.handle("key.2", pressed: false, pid: 123)
        expect(automatic.isObserving && automatic.ledger.totals.sessions == 0, "press or release during recording never ends it")
        automatic.microphoneChanged(.idle, pid: 123); automatic.microphoneChanged(.idle, pid: 123)
        try await Task.sleep(nanoseconds: 2_100_000_000)
        expect(automatic.ledger.totals.observedCharacters == 4 && automatic.ledger.totals.sessions == 1, "automatic mic cycle counted once with observed output")
        await automatic.flush()
        var zeroReceipt: PassiveInputObserver.Receipt?
        let unchanged = PassiveInputObserver(settleSeconds: 0.5, readerFactory: { _ in .init(before: before, read: { before }) }, completed: { zeroReceipt = $0 })
        let zeroID = UUID(); unchanged.begin(id: zeroID, at: now, uptime: ProcessInfo.processInfo.systemUptime - 30, pid: 123)
        unchanged.end(id: zeroID, uptime: ProcessInfo.processInfo.systemUptime)
        try await Task.sleep(nanoseconds: 850_000_000)
        expect(zeroReceipt?.characters == 0 && zeroReceipt?.failure == nil, "no sampled text does not fabricate an observed count")
        var rapidText = "", rapidReceipts: [PassiveInputObserver.Receipt] = []
        let rapid = PassiveInputObserver(readerFactory: { _ in
            let baseline = rapidText
            return .init(before: .init(text: baseline, selection: .init(location: baseline.utf16.count, length: 0)), read: {
                .init(text: rapidText, selection: .init(location: rapidText.utf16.count, length: 0))
            })
        }, completed: { rapidReceipts.append($0) })
        let firstID = UUID(), secondID = UUID(), rapidStart = ProcessInfo.processInfo.systemUptime
        rapid.begin(id: firstID, at: now, uptime: rapidStart - 1, pid: 123)
        try await Task.sleep(nanoseconds: 100_000_000); rapidText = "第一句"
        rapid.end(id: firstID, uptime: rapidStart)
        rapid.begin(id: secondID, at: now, uptime: rapidStart, pid: 123)
        try await Task.sleep(nanoseconds: 100_000_000); rapidText += "第二句"
        rapid.end(id: secondID, uptime: ProcessInfo.processInfo.systemUptime + 0.3)
        try await Task.sleep(nanoseconds: 2_200_000_000)
        expect(rapidReceipts.count == 2 && rapidReceipts.compactMap(\.characters).reduce(0, +) == 6, "rapid consecutive recordings preserve both outputs without overlap")
        let beforePause = automatic.ledger.totals
        automatic.update { $0.enabled = false }; automatic.microphoneChanged(.active, pid: 123)
        expect(!automatic.isObserving && automatic.ledger.totals == beforePause, "pause cancels automatic input and preserves aggregates")
        let secure = UsageStatisticsStore(directory: folder.appendingPathComponent("secure"), observeHardware: false, readerFactory: { _ in throw InputObservationFailure.secure })
        secure.setCollectionEnabled(true)
        secure.microphoneChanged(.active, pid: 123); try await Task.sleep(nanoseconds: 350_000_000); secure.microphoneChanged(.idle, pid: 123)
        try await Task.sleep(nanoseconds: 100_000_000)
        expect(secure.ledger.totals.estimatedCharacters == 0 && secure.ledger.totals.unavailableSessions == 1, "protected fields never receive automatic duration estimates")
        await secure.flush(); await automatic.flush()
        let focusLost = UsageStatisticsStore(directory: folder.appendingPathComponent("focus-lost"), observeHardware: false, readerFactory: { _ in throw InputObservationFailure.targetChanged })
        focusLost.setCollectionEnabled(true)
        focusLost.microphoneChanged(.active, pid: 123)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        expect(focusLost.displayLedger.totals.estimatedCharacters > 0 && focusLost.ledger.totals.sessions == 0, "focus loss has continuously updated explicit estimate while recording")
        focusLost.microphoneChanged(.idle, pid: 123)
        try await Task.sleep(nanoseconds: 100_000_000)
        expect(focusLost.ledger.totals.estimatedCharacters > 0 && focusLost.ledger.totals.unavailableSessions == 0, "focus loss no longer discards an otherwise valid microphone session")
        expect(focusLost.ledger.totals.observationFailures?[InputObservationFailure.targetChanged.rawValue] == 1, "failure counts retained without input text for later diagnosis")
        let focusAmount = focusLost.ledger.totals.totalCharacters
        focusLost.microphoneChanged(.idle, pid: 123)
        expect(focusLost.displayLedger.totals.totalCharacters == focusAmount && focusLost.ledger.totals.sessions == 1, "live estimate merges once without double counting")
        var failedReads = 0
        let recovering = UsageStatisticsStore(directory: folder.appendingPathComponent("recovering"), observeHardware: false, readerFactory: { _ in
            .init(before: before, read: {
                failedReads += 1
                if failedReads < 3 { throw InputObservationFailure.targetChanged }
                return draft("语音输入")
            })
        })
        recovering.setCollectionEnabled(true)
        recovering.microphoneChanged(.active, pid: 123)
        try await Task.sleep(nanoseconds: 1_150_000_000)
        expect(recovering.displayLedger.totals.observedCharacters == 4 && recovering.ledger.totals.sessions == 0, "temporary focus loss retries the frozen field and recovers live received count")
        recovering.update { $0.enabled = false }
        expect(recovering.ledger.totals.observedCharacters == 4 && recovering.liveSummary == nil, "pause preserves received amount and clears provisional overlay")
        var partialReads = 0
        let partial = UsageStatisticsStore(directory: folder.appendingPathComponent("partial"), observeHardware: false, readerFactory: { _ in
            .init(before: before, read: {
                partialReads += 1
                if partialReads > 1 { throw InputObservationFailure.targetChanged }
                return draft("已收")
            })
        })
        partial.setCollectionEnabled(true)
        partial.microphoneChanged(.active, pid: 123)
        try await Task.sleep(nanoseconds: 1_650_000_000)
        expect(partial.displayLedger.totals.estimatedCharacters >= 4, "unrecovered partial focus loss covers the rest of microphone usage with a labeled estimate")
        partial.stop(); await partial.flush()
        expect(partial.ledger.totals.estimatedCharacters >= 4 && partial.ledger.totals.sessions == 1, "shutdown preserves one partial/estimated session without waiting for final text")
        let noSample = UsageStatisticsStore(directory: folder.appendingPathComponent("no-sample"), observeHardware: false, readerFactory: { _ in .init(before: before, read: { before }) })
        noSample.setCollectionEnabled(true)
        noSample.microphoneChanged(.active, pid: 123)
        try await Task.sleep(nanoseconds: 800_000_000)
        expect(noSample.displayLedger.totals.estimatedCharacters >= 1 && noSample.liveSummary?.contains("估算") == true, "fast insert-and-send or unreadable interim input retains live duration estimate rather than looking stuck at zero")
        noSample.stop(); await noSample.flush()
        expect(noSample.ledger.totals.estimatedSessions == 1 && noSample.ledger.totals.observedCharacters == 0, "missing samples are explicitly estimated, never labeled observed")
        await focusLost.flush(); await recovering.flush()
        print("PASS: \(checks) passive statistics checks; no external input, microphone or device action executed")
    }
}
