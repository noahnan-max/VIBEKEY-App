import Foundation
import VibekeyCore

/// The full device/host snapshot remains local. The index contains only the
/// owned filename, and pending transactions survive application restarts.
final class AU05SmartArchive {
    struct Backup: Codable { let schemaVersion: Int; let createdAt: Date; let snapshot: AU05SmartSnapshot }
    struct Journal: Codable { let schemaVersion: Int; let backup: String; var phase: String }
    let directory: URL
    private var index: URL { directory.appendingPathComponent("transaction.json") }
    init(directory: URL) { self.directory = directory }
    func journal() throws -> Journal? {
        guard FileManager.default.fileExists(atPath: index.path) else { return nil }
        let data = try privateData(index)
        let value = try JSONDecoder().decode(Journal.self, from: data)
        guard value.schemaVersion == 1, ["pending", "saved", "restored", "notWritten", "recoveryRequired"].contains(value.phase),
              value.backup == URL(fileURLWithPath: value.backup).lastPathComponent, value.backup.hasPrefix("au05-"), value.backup.hasSuffix(".json") else { throw AU05ShortcutError.storage }
        _ = try load(url(value)); return value
    }
    func url(_ value: Journal) -> URL { directory.appendingPathComponent("Backups").appendingPathComponent(value.backup) }
    func load(_ url: URL) throws -> AU05SmartSnapshot {
        guard url.standardizedFileURL.deletingLastPathComponent() == directory.appendingPathComponent("Backups").standardizedFileURL else { throw AU05ShortcutError.storage }
        let backup = try JSONDecoder().decode(Backup.self, from: privateData(url))
        guard backup.schemaVersion == 1 else { throw AU05ShortcutError.storage }; try backup.snapshot.validate(); return backup.snapshot
    }
    func begin(_ snapshot: AU05SmartSnapshot) throws -> URL {
        try snapshot.validate(); let name = "au05-" + UUID().uuidString + ".json"
        let value = Journal(schemaVersion: 1, backup: name, phase: "pending"), target = url(value)
        try SmartPrivateFiles.write(JSONEncoder().encode(Backup(schemaVersion: 1, createdAt: Date(), snapshot: snapshot)), to: target)
        guard try load(target) == snapshot else { throw AU05ShortcutError.storage }
        try SmartPrivateFiles.write(JSONEncoder().encode(value), to: index)
        guard try journal()?.backup == name else { throw AU05ShortcutError.storage }; return target
    }
    func finish(_ phase: String) throws {
        guard var value = try journal() else { throw AU05ShortcutError.storage }; value.phase = phase
        try SmartPrivateFiles.write(JSONEncoder().encode(value), to: index)
    }
    private func privateData(_ url: URL) throws -> Data {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeRegular, ((a[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0,
              ((a[.size] as? NSNumber)?.intValue ?? Int.max) <= 2 * 1024 * 1024 else { throw AU05ShortcutError.storage }
        return try Data(contentsOf: url)
    }
}
