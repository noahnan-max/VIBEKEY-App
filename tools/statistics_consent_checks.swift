import Foundation
import VibekeyCore

@main @MainActor enum StatisticsConsentChecks {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        precondition(value, message); checks += 1
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("usage-consent-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var reads = 0
        let before = InputFieldSnapshot(text: "", selection: .init(location: 0, length: 0))
        let after = InputFieldSnapshot(text: "合成", selection: .init(location: 2, length: 0))
        func store(_ directory: URL) -> UsageStatisticsStore {
            UsageStatisticsStore(directory: directory, observeHardware: false, readerFactory: { _ in
                reads += 1; return .init(before: before, read: { after })
            })
        }
        let freshDirectory = root.appendingPathComponent("fresh")
        let fresh = store(freshDirectory)
        fresh.start(); fresh.handle("key.0", pressed: true, pid: 123); fresh.microphoneChanged(.active, pid: 123)
        try await Task.sleep(nanoseconds: 350_000_000)
        check(!fresh.collectionEnabled && !fresh.isObserving && reads == 0, "First launch must not observe text")
        check(!FileManager.default.fileExists(atPath: freshDirectory.appendingPathComponent("usage.json").path), "No pre-consent history created")
        fresh.update { $0.enabled = true }
        fresh.microphoneChanged(.active, pid: 123)
        check(!fresh.collectionEnabled && reads == 0, "An enabled flag alone cannot grant observation consent")
        await fresh.flush()

        let legacyDirectory = root.appendingPathComponent("legacy")
        var ledger = UsageStatisticsLedger(); ledger.preferences.enabled = true
        ledger.record(at: Date(), seconds: 3, characters: 17, source: .observed)
        try UsageStatisticsFile.save(ledger, directory: legacyDirectory)
        let path = legacyDirectory.appendingPathComponent("usage.json"), original = try Data(contentsOf: path)
        let legacy = store(legacyDirectory)
        legacy.start(); legacy.handle("key.0", pressed: true, pid: 123); legacy.microphoneChanged(.active, pid: 123)
        try await Task.sleep(nanoseconds: 350_000_000)
        check(legacy.preferences.enabled && !legacy.collectionEnabled && reads == 0, "Legacy default kept without silently granting consent")
        let afterOpening = try Data(contentsOf: path)
        check(legacy.ledger.days == ledger.days && afterOpening == original, "Opening preserves legacy aggregate bytes")
        legacy.update { $0.typingCharactersPerMinute = 90 }; await legacy.flush()
        check(!legacy.collectionEnabled && legacy.preferences.observationConsentVersion == nil, "Changing rate cannot enable text observation")
        legacy.setCollectionEnabled(true); await legacy.flush()
        check(legacy.collectionEnabled && legacy.preferences.observationConsentVersion == 1, "Explicit enable records versioned consent")
        legacy.microphoneChanged(.active, pid: 123)
        try await Task.sleep(nanoseconds: 600_000_000)
        check(reads == 1 && legacy.isObserving && legacy.displayLedger.totals.observedCharacters == 19, "Opt-in enables live observation and retains old totals")
        legacy.stop(); await legacy.flush()
        let reopened = store(legacyDirectory)
        check(reopened.collectionEnabled && reopened.ledger.totals.observedCharacters == 19, "Explicit opt-in and totals survive reopen")
        reopened.setCollectionEnabled(false); await reopened.flush()
        let paused = store(legacyDirectory)
        paused.start(); paused.microphoneChanged(.active, pid: 123)
        check(!paused.collectionEnabled && paused.preferences.observationConsentVersion == 1 && reads == 1, "Pause survives reopen and blocks reads")
        check(paused.ledger.totals.observedCharacters == 19, "Pause does not remove prior totals")

        let futureDirectory = root.appendingPathComponent("future")
        var future = ledger; future.preferences.observationConsentVersion = 2
        try FileManager.default.createDirectory(at: futureDirectory, withIntermediateDirectories: true)
        let futurePath = futureDirectory.appendingPathComponent("usage.json")
        let futureBytes = try JSONEncoder().encode(future); try futureBytes.write(to: futurePath)
        let unsupported = store(futureDirectory)
        unsupported.setCollectionEnabled(true); unsupported.start(); unsupported.microphoneChanged(.active, pid: 123)
        await unsupported.flush()
        check(!unsupported.canChangePreferences && !unsupported.isObserving && reads == 1, "Unknown consent version fails closed")
        check(try Data(contentsOf: futurePath) == futureBytes, "Future file must not be replaced with defaults")
        print("PASS: \(checks) public statistics consent and history checks; external reads 0, synthetic reader only")
    }
}
