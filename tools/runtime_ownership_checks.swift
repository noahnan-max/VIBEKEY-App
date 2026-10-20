import Foundation
import Darwin

/// Only a self-started fixture worker. It has no application/device services.
@main struct RuntimeOwnershipWorker {
    static func emit(_ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }
    static func argument(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }
    static func errorKind(_ error: Error) -> String {
        guard let value = error as? RuntimeOwnership.OwnershipError else { return "other" }
        switch value {
        case .invalidDirectory: return "invalidDirectory"
        case .unsafePath: return "unsafePath"
        case .unsafePermissions: return "unsafePermissions"
        case .nonLocalFilesystem: return "nonLocalFilesystem"
        case .pathChanged: return "pathChanged"
        case .unavailable(let code): return "unavailable:\(code)"
        case .writeFailed(let code): return "writeFailed:\(code)"
        }
    }
    static func acquire(_ directory: URL) throws -> RuntimeOwnership.Lease? {
        switch try RuntimeOwnership.acquire(directory: directory) {
        case .alreadyOwned: emit(["status": "ALREADY_OWNED"]); return nil
        case .acquired(let lease):
            emit(["status": "ACQUIRED", "held": lease.isHeld, "closeOnExec": lease.auditCloseOnExec])
            return lease
        }
    }
    static func main() {
        // A fixture that loses its runner exits itself; no other PID is killed.
        _ = Darwin.alarm(45)
        guard let path = argument("--directory"), let mode = argument("--mode") else { exit(64) }
        let prefix = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Caches/Vibekey/OwnedProbes/runtime-owner-v33-"
        guard path.hasPrefix(prefix), !path.contains("/../"), !path.contains("/./") else { emit(["status": "REFUSED_FIXTURE_PATH"]); exit(64) }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        do {
            if mode == "invalid-url" {
                _ = try RuntimeOwnership.acquire(directory: URL(string: "https://example.invalid/runtime")!)
                emit(["status": "UNEXPECTED_SUCCESS"]); return
            }
            if mode == "invalid-root" {
                _ = try RuntimeOwnership.acquire(directory: URL(fileURLWithPath: "/", isDirectory: true))
                emit(["status": "UNEXPECTED_SUCCESS"]); return
            }
            var lease: RuntimeOwnership.Lease?
            if mode == "wait" { emit(["status": "EXEC_WITHOUT_LEASE"]) }
            else { lease = try acquire(directory) }
            if mode == "once" { lease?.release(); return }
            while let command = readLine() {
                switch command {
                case "release":
                    lease?.release(); lease?.release()
                    emit(["status": "RELEASED", "held": lease?.isHeld ?? false]); return
                case "drop":
                    lease = nil; emit(["status": "DROPPED"])
                case "same-process":
                    switch try RuntimeOwnership.acquire(directory: directory) {
                    case .alreadyOwned: emit(["status": "ALREADY_OWNED"])
                    case .acquired(let extra): emit(["status": "UNEXPECTED_SECOND_OWNER"]); extra.release()
                    }
                case "open-close":
                    let fd = Darwin.open(directory.appendingPathComponent(RuntimeOwnership.lockFilename).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { emit(["status": "OPEN_FAILED"]); continue }
                    _ = Darwin.close(fd); emit(["status": "UNRELATED_DESCRIPTOR_CLOSED"])
                case "crash":
                    // Deliberately bypass Swift deinit in this fixture only.
                    Darwin._exit(42)
                case "exec":
                    let executable = CommandLine.arguments[0]
                    let values = [executable, "--directory", path, "--mode", "wait"]
                    let pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) } + [nil]
                    pointers.withUnsafeBufferPointer { buffer in
                        _ = Darwin.execv(executable, UnsafeMutablePointer(mutating: buffer.baseAddress!))
                    }
                    for pointer in pointers { if let pointer { free(pointer) } }
                    emit(["status": "EXEC_FAILED", "errno": errno])
                default: emit(["status": "UNKNOWN_COMMAND"])
                }
            }
            lease?.release()
        } catch {
            emit(["status": "ERROR", "kind": errorKind(error)])
            exit(2)
        }
    }
}
