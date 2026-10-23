import Foundation
import Security
import LocalAuthentication
import CryptoKit
import Darwin
import VibekeyCore

enum SmartPrivateFiles {
    static func directory(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileWriteInvalidFileName) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    /// Unique temporary files start private, are fsynced, atomically promoted,
    /// and byte-checked. A backup failure is propagated before any HID write.
    static func write(_ data: Data, to url: URL) throws {
        try directory(url.deletingLastPathComponent())
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileWriteInvalidFileName) }
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".smart-\(UUID().uuidString)")
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(fd); try? fm.removeItem(at: temporary) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += count
            }
        }
        guard Darwin.fsync(fd) == 0, Darwin.rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let parent = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(parent) }
        guard Darwin.fsync(parent) == 0, try Data(contentsOf: url) == data else { throw CocoaError(.fileReadCorruptFile) }
    }
}

@MainActor
final class SmartConfigurationPreferences {
    private let directory: URL
    private let service = "io.github.noahnan-max.VIBEKEY.smart-configuration"
    private let keyReader: (@Sendable (String) throws -> String)?
    private var cachedKeys: [String: String] = [:]
    private var keyReads: [String: (id: UUID, task: Task<String, Error>)] = [:]
    private var credentialRevision = 0
    init(directory: URL, keyReader: (@Sendable (String) throws -> String)? = nil) { self.directory = directory; self.keyReader = keyReader }
    func load() throws -> SmartModelSettings {
        let url = directory.appendingPathComponent("model.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return SmartModelSettings() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue < 16_384 else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(SmartModelSettings.self, from: Data(contentsOf: url))
    }
    func save(_ settings: SmartModelSettings, newKey: String?) async throws {
        try settings.validate()
        if settings.provider == .openAICompatible, let newKey, !newKey.isEmpty {
            guard newKey.utf8.count <= 4096, !newKey.contains("\n"), !newKey.contains("\r") else { throw SmartModelError.settings }
            let reference = SmartKeychainReference(query: keyQuery(settings))
            cachedKeys.removeAll(); keyReads.removeAll(); credentialRevision += 1
            try await Task.detached(priority: .userInitiated) { try SmartKeychainAccess.save(reference, key: newKey) }.value
            try Task.checkCancellation()
            cachedKeys[try settings.endpoint().absoluteString] = newKey
        }
        try Task.checkCancellation()
        try SmartPrivateFiles.write(JSONEncoder().encode(settings), to: directory.appendingPathComponent("model.json"))
    }
    var hasSavedSettings: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.json").path) }
    func key(_ settings: SmartModelSettings) async throws -> String {
        guard settings.provider == .openAICompatible else { return "" }
        let endpoint = try settings.endpoint().absoluteString
        if let value = cachedKeys[endpoint] { try Task.checkCancellation(); return value }
        let revision = credentialRevision
        let read: (id: UUID, task: Task<String, Error>)
        if let pending = keyReads[endpoint] { read = pending }
        else {
            let reference = SmartKeychainReference(query: keyQuery(settings)), reader = keyReader
            read = (UUID(), Task.detached(priority: .userInitiated) { try reader?(endpoint) ?? SmartKeychainAccess.read(reference) })
            keyReads[endpoint] = read
        }
        defer { if keyReads[endpoint]?.id == read.id { keyReads[endpoint] = nil } }
        let value = try await read.task.value
        try Task.checkCancellation()
        guard revision == credentialRevision else { throw SmartSecretFailure() }
        if !value.isEmpty { cachedKeys[endpoint] = value }
        return value
    }
    func hasKey(_ settings: SmartModelSettings) -> Bool {
        guard hasSavedSettings, settings.provider == .openAICompatible else { return false }
        var query = keyQuery(settings); query[kSecReturnAttributes] = true
        let context = LAContext(); context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext] = context
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
    func deleteKey(_ settings: SmartModelSettings) async throws {
        cachedKeys.removeAll(); keyReads.removeAll(); credentialRevision += 1
        let reference = SmartKeychainReference(query: keyQuery(settings))
        try await Task.detached(priority: .userInitiated) { try SmartKeychainAccess.delete(reference) }.value
    }
    private func keyQuery(_ settings: SmartModelSettings) -> [CFString: Any] {
        // A key saved for one endpoint is never forwarded to a different endpoint.
        let endpoint = (try? settings.endpoint().absoluteString) ?? settings.baseURL
        let bytes = Data((directory.standardizedFileURL.path + "\n" + endpoint).utf8)
        let account = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }
}

// Queries contain only locally built immutable service/account selectors.
// Security.framework may wait for a protected macOS authorization dialog;
// those calls must never occupy the main actor or stop HID event processing.
private struct SmartKeychainReference: @unchecked Sendable { let query: [CFString: Any] }
private enum SmartKeychainAccess {
    static func read(_ reference: SmartKeychainReference) throws -> String {
        guard !Thread.isMainThread else { throw SmartSecretFailure() }
        var query = reference.query; query[kSecReturnData] = true; query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw SmartSecretFailure() }; return key
    }
    static func save(_ reference: SmartKeychainReference, key: String) throws {
        guard !Thread.isMainThread else { throw SmartSecretFailure() }
        var query = reference.query; let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData] = data; query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw SmartSecretFailure() }
        } else if status != errSecSuccess { throw SmartSecretFailure() }
    }
    static func delete(_ reference: SmartKeychainReference) throws {
        guard !Thread.isMainThread else { throw SmartSecretFailure() }
        let status = SecItemDelete(reference.query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SmartSecretFailure() }
    }
}
private struct SmartSecretFailure: Error, LocalizedError {
    var errorDescription: String? { "模型密钥无法读取或保存。请在 macOS 系统窗口完成钥匙串授权后重试；密码不要填入聊天。" }
}
