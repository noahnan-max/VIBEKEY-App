import Foundation
import VibekeyCore

private final class Reader: @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [String: Int] = [:]
    var empty = false
    func read(_ endpoint: String) -> String {
        lock.lock(); reads[endpoint, default: 0] += 1; let empty = empty; lock.unlock()
        Thread.sleep(forTimeInterval: 0.08)
        return empty ? "" : "fixture-key-for-" + endpoint
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return reads.values.reduce(0, +) }
}

@main @MainActor enum SmartCredentialCacheChecks {
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw NSError(domain: "CacheCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            count += 1
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smart-cache-" + UUID().uuidString)
        let reader = Reader()
        let store = SmartConfigurationPreferences(directory: directory, keyReader: { reader.read($0) })
        let a = SmartModelSettings(baseURL: "https://a.example/v1", model: "fixture")
        let b = SmartModelSettings(baseURL: "https://b.example/v1", model: "fixture")
        async let one = store.key(a)
        async let two = store.key(a)
        let values = try await (one, two)
        try check(values.0 == values.1 && !values.0.isEmpty && reader.count == 1, "Concurrent reads did not share one authorization")
        let repeated = try await store.key(a)
        try check(repeated == values.0 && reader.count == 1, "Successful key was read again")
        let different = try await store.key(b)
        try check(different != repeated && reader.count == 2, "A key was forwarded to another endpoint")
        _ = try await store.key(.init(baseURL: a.baseURL, model: "another-model"))
        try check(reader.count == 2, "Model selection unnecessarily re-read the same endpoint key")
        _ = try await store.key(.init(provider: .codexLogin))
        try check(reader.count == 2, "Codex login accessed an API credential")
        let cancelledReader = Reader()
        let cancelledStore = SmartConfigurationPreferences(directory: directory, keyReader: { cancelledReader.read($0) })
        let cancelled = Task { try await cancelledStore.key(a) }
        try await Task.sleep(nanoseconds: 20_000_000); cancelled.cancel()
        let retry = Task { try await cancelledStore.key(a) }
        do { _ = try await cancelled.value; throw NSError(domain: "CacheCheck", code: 2) }
        catch is CancellationError { count += 1 }
        let retried = try await retry.value
        try check(!retried.isEmpty && cancelledReader.count == 1, "Retry after cancellation duplicated a pending authorization")
        let emptyReader = Reader(); emptyReader.empty = true
        let emptyStore = SmartConfigurationPreferences(directory: directory, keyReader: { emptyReader.read($0) })
        _ = try await emptyStore.key(a); _ = try await emptyStore.key(a)
        try check(emptyReader.count == 2, "Missing key was cached and could not recover")
        try check(!FileManager.default.fileExists(atPath: directory.path), "Credential fixture wrote a file")
        print("{\"result\":\"PASS\",\"checks\":\(count),\"keychainAccesses\":0,\"credentialFilesWritten\":0}")
    }
}
