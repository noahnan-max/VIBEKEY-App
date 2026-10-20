import Foundation
import Darwin

public struct AU05ShortcutJournal: Codable {
    public let schemaVersion: Int
    public let id: UUID
    public let createdAt: Date
    public let original: AU05OnboardShortcut
    public let target: AU05OnboardShortcut
    public var phase: String
    public init(original: AU05OnboardShortcut, target: AU05OnboardShortcut) {
        schemaVersion = 1; id = UUID(); createdAt = Date(); self.original = original; self.target = target; phase = "pending"
    }
}

public final class AU05ShortcutArchive {
    public let directory: URL
    private var current: URL { directory.appendingPathComponent("last-transaction.json") }
    public init(directory: URL) { self.directory = directory }
    public func pending() throws -> AU05ShortcutJournal? {
        do { _ = try FileManager.default.attributesOfItem(atPath: current.path) }
        catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError { return nil }
            throw AU05ShortcutError.storage
        }
        try check(directory, directory: true)
        try check(current, directory: false)
        let record = try JSONDecoder().decode(AU05ShortcutJournal.self, from: Data(contentsOf: current))
        guard record.schemaVersion == 1, record.original.index == record.target.index,
              record.original.writable, record.target.writable else { throw AU05ShortcutError.storage }
        guard ["pending", "recoveryRequired", "saved", "restored"].contains(record.phase) else { throw AU05ShortcutError.storage }
        return ["pending", "recoveryRequired"].contains(record.phase) ? record : nil
    }
    public func begin(_ record: AU05ShortcutJournal) throws {
        try prepareDirectory()
        let backup = directory.appendingPathComponent("backup-" + record.id.uuidString + ".json")
        guard !FileManager.default.fileExists(atPath: backup.path) else { throw AU05ShortcutError.storage }
        try write(record, to: backup); try write(record, to: current)
    }
    public func finish(_ record: AU05ShortcutJournal) throws { try prepareDirectory(); try write(record, to: current) }
    private func prepareDirectory() throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try check(directory, directory: true)
    }
    private func check(_ url: URL, directory: Bool) throws {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
              ((a[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0,
              (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw AU05ShortcutError.storage }
    }
    private func write(_ record: AU05ShortcutJournal, to url: URL) throws {
        if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil { try check(url, directory: false) }
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }; try file.synchronize()
        guard try Data(contentsOf: url) == data else { throw AU05ShortcutError.storage }
    }
}

@MainActor public struct AU05ShortcutAdapter {
    public var available: () -> Bool
    public var read: (UInt8) async throws -> AU05OnboardShortcut
    public var write: (AU05OnboardShortcut) async throws -> Void
    public init(available: @escaping () -> Bool, read: @escaping (UInt8) async throws -> AU05OnboardShortcut,
                write: @escaping (AU05OnboardShortcut) async throws -> Void) {
        self.available = available; self.read = read; self.write = write
    }
}

/// Single-slot, compare-before-write transaction. Unknown concurrent changes are
/// never overwritten in the name of recovery. Journals survive app termination.
@MainActor public final class AU05ShortcutTransaction {
    public private(set) var isBusy = false
    public private(set) var recovery: AU05ShortcutJournal?
    private let archive: AU05ShortcutArchive
    public init(archive: AU05ShortcutArchive) throws { self.archive = archive; recovery = try archive.pending() }
    public func save(original: AU05OnboardShortcut, target: AU05OnboardShortcut, adapter: AU05ShortcutAdapter) async throws {
        guard !isBusy, recovery == nil else { throw AU05ShortcutError.busy }
        guard original.index == target.index, original.writable, target.writable else { throw AU05ShortcutError.unsupported }
        isBusy = true; defer { isBusy = false }
        guard adapter.available() else { throw AU05ShortcutError.disconnected }
        let current = try await adapter.read(original.index)
        guard current == original else { throw AU05ShortcutError.changed }
        if original == target { return }
        var record = AU05ShortcutJournal(original: original, target: target)
        try archive.begin(record); recovery = record
        guard adapter.available(), !Task.isCancelled else {
            record.phase = "restored"; try archive.finish(record); recovery = nil
            throw AU05ShortcutError.disconnected
        }
        do {
            try await adapter.write(target)
            guard adapter.available() else { throw AU05ShortcutError.disconnected }
            guard try await adapter.read(target.index) == target else { throw AU05ShortcutError.invalidReply }
            record.phase = "saved"; try archive.finish(record); recovery = nil
        } catch {
            do { try await restore(record, adapter: adapter) }
            catch { record.phase = "recoveryRequired"; try? archive.finish(record); recovery = record; throw AU05ShortcutError.recoveryRequired }
            throw AU05ShortcutError.restored
        }
    }
    public func recover(adapter: AU05ShortcutAdapter) async throws {
        guard !isBusy else { throw AU05ShortcutError.busy }
        guard let record = recovery else { return }
        isBusy = true; defer { isBusy = false }
        try await restore(record, adapter: adapter)
    }
    private func restore(_ initial: AU05ShortcutJournal, adapter: AU05ShortcutAdapter) async throws {
        guard adapter.available() else { throw AU05ShortcutError.recoveryRequired }
        let current = try await adapter.read(initial.original.index)
        if current != initial.original {
            guard current == initial.target, adapter.available() else { throw AU05ShortcutError.recoveryRequired }
            try await adapter.write(initial.original)
            guard adapter.available(), try await adapter.read(initial.original.index) == initial.original else { throw AU05ShortcutError.recoveryRequired }
        }
        var record = initial; record.phase = "restored"; try archive.finish(record); recovery = nil
    }
}
