import Foundation
import Darwin

public enum WorkflowPersistence {
    private struct Document: Codable {
        var schemaVersion: Int
        var bindings: [WorkflowBinding]
    }

    private static let lock = NSLock()
    private static let maximumFileSize = 1_048_576

    public static func load(from url: URL) throws -> [WorkflowBinding] {
        lock.lock()
        defer { lock.unlock() }
        return try read(from: url)
    }

    public static func save(_ bindings: [WorkflowBinding], to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard url.isFileURL else { throw WorkflowError.invalidConfiguration("工作流只能保存到本地文件。") }
        try WorkflowValidation.validate(bindings)
        // Validate the existing document before replacing it, including future versions.
        // A decoding failure is never converted to an empty configuration.
        if FileManager.default.fileExists(atPath: url.path) { _ = try read(from: url) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(schemaVersion: 1, bindings: bindings))
        guard data.count <= maximumFileSize else { throw WorkflowError.invalidConfiguration("工作流文件超过 1 MB 上限。") }
        try writeAtomically(data, to: url)
    }

    private static func read(from url: URL) throws -> [WorkflowBinding] {
        guard url.isFileURL else { throw WorkflowError.invalidConfiguration("工作流只能从本地文件读取。") }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximumFileSize else {
            throw WorkflowError.damagedConfiguration
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumFileSize else { throw WorkflowError.damagedConfiguration }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw WorkflowError.damagedConfiguration }
        guard document.schemaVersion == 1 else { throw WorkflowError.unsupportedConfigurationVersion }
        do { try WorkflowValidation.validate(document.bindings) }
        catch { throw WorkflowError.damagedConfiguration }
        return document.bindings
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".vibekey-\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw WorkflowError.systemFailure("无法创建工作流临时文件。")
        }
        defer { try? manager.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        // Same-directory rename is atomic and retains the temporary file's 0600 mode.
        let result = temporary.path.withCString { source in
            url.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard result == 0 else { throw WorkflowError.systemFailure("无法原子替换工作流文件（系统错误 \(errno)）。") }
    }
}
