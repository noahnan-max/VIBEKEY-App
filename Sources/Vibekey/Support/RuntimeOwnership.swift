import Foundation
import Darwin

/// One cooperating process per private runtime directory. Acquire before any
/// device, shortcut or store service is constructed. File existence and
/// contents are never evidence of ownership; only the OS advisory lock is.
enum RuntimeOwnership {
    static let lockFilename = "runtime-owner.lock"

    enum Acquisition {
        case acquired(Lease)
        case alreadyOwned
    }

    enum OwnershipError: Error, LocalizedError, Equatable {
        case invalidDirectory, unsafePath, unsafePermissions, nonLocalFilesystem
        case pathChanged, unavailable(Int32), writeFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidDirectory:
                return "VIBEKEY 运行目录无效，尚未启动设备和快捷键服务。"
            case .unsafePath:
                return "VIBEKEY 运行锁路径不是安全的普通文件或目录，尚未启动服务。"
            case .unsafePermissions:
                return "VIBEKEY 运行目录或锁文件权限不符合私有存储要求，尚未启动服务。"
            case .nonLocalFilesystem:
                return "VIBEKEY 运行锁需要本机磁盘目录，尚未启动服务。"
            case .pathChanged:
                return "VIBEKEY 运行锁路径在检查时发生变化，尚未启动服务。"
            case .unavailable(let code):
                return "无法取得 VIBEKEY 运行锁（系统状态 \(code)），尚未启动服务。"
            case .writeFailed(let code):
                return "VIBEKEY 运行锁未能写入并核验（系统状态 \(code)），尚未启动服务。"
            }
        }
    }

    /// Retain for the full runtime lifetime. Releasing never removes the inode:
    /// unlinking a held lock would let another process lock a different file.
    final class Lease {
        let directory: URL
        private let mutex = NSLock()
        private var descriptor: Int32

        fileprivate init(directory: URL, descriptor: Int32) {
            self.directory = directory; self.descriptor = descriptor
        }
        var isHeld: Bool {
            mutex.lock(); defer { mutex.unlock() }
            return descriptor >= 0
        }
        func release() {
            mutex.lock(); defer { mutex.unlock() }
            guard descriptor >= 0 else { return }
            let owned = descriptor; descriptor = -1
            // flock uses last-close semantics. Do not unlock a duplicate/forked
            // file description that might still be in use by its owner.
            _ = Darwin.close(owned)
        }
        deinit { release() }
    }

    /// `directory` is dedicated to runtime ownership, not a shared cache parent.
    /// Existing permissions are checked, never silently repaired. A probe must
    /// pass its own isolated directory instead of the formal runtime directory.
    static func acquire(directory: URL) throws -> Acquisition {
        guard directory.isFileURL, directory.path.hasPrefix("/"),
              !directory.path.utf8.contains(0), directory.path != "/",
              !directory.pathComponents.contains(".."), !directory.pathComponents.contains(".") else {
            throw OwnershipError.invalidDirectory
        }
        let url = directory.standardizedFileURL
        let parent = try openDirectory(url, create: true)
        defer { _ = Darwin.close(parent) }
        var filesystem = statfs()
        guard Darwin.fstatfs(parent, &filesystem) == 0 else { throw OwnershipError.unavailable(errno) }
        guard UInt64(filesystem.f_flags) & UInt64(MNT_LOCAL) != 0 else { throw OwnershipError.nonLocalFilesystem }

        var existing = stat()
        if Darwin.fstatat(parent, lockFilename, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            try validateFile(existing)
        } else if errno != ENOENT { throw OwnershipError.unavailable(errno) }

        // Darwin O_EXLOCK obtains the flock-style lock as part of open. It has
        // descriptor/last-close semantics, unlike POSIX fcntl record locks that
        // can be lost when an unrelated descriptor to the file is closed.
        let flags = O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | O_EXLOCK
        var descriptor = Darwin.openat(parent, lockFilename, flags, 0o600)
        var retries = 0
        while descriptor < 0, errno == EINTR, retries < 3 {
            retries += 1
            descriptor = Darwin.openat(parent, lockFilename, flags, 0o600)
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN {
                var named = stat()
                guard Darwin.fstatat(parent, lockFilename, &named, AT_SYMLINK_NOFOLLOW) == 0 else { throw OwnershipError.pathChanged }
                try validateFile(named)
                try verifyDirectoryIdentity(parent, directory: url)
                return .alreadyOwned
            }
            if code == ELOOP || code == EISDIR { throw OwnershipError.unsafePath }
            throw OwnershipError.unavailable(code)
        }
        var transferred = false
        defer { if !transferred { _ = Darwin.close(descriptor) } }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0 else { throw OwnershipError.unavailable(errno) }
        try validateFile(opened)
        try verifyIdentity(parent: parent, descriptor: descriptor)

        // Re-open the directory without creation to reject a path replacement
        // between traversal and acquisition. No PID or stale contents are read.
        try verifyDirectoryIdentity(parent, directory: url)

        // Write only after exclusive ownership. A loser must not truncate or
        // replace the winner's file. This header is diagnostic, not a PID lock.
        let header = Array("VIBEKEY runtime ownership v1\n".utf8)
        guard Darwin.ftruncate(descriptor, 0) == 0, Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw OwnershipError.writeFailed(errno)
        }
        try header.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw OwnershipError.writeFailed(count == 0 ? EIO : errno) }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw OwnershipError.writeFailed(errno) }
        try verifyIdentity(parent: parent, descriptor: descriptor)
        let lease = Lease(directory: url, descriptor: descriptor)
        transferred = true
        return .acquired(lease)
    }

    private static func validateFile(_ info: stat) throws {
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else { throw OwnershipError.unsafePath }
        guard info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o600 else { throw OwnershipError.unsafePermissions }
    }
    private static func verifyIdentity(parent: Int32, descriptor: Int32) throws {
        var opened = stat(), named = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              Darwin.fstatat(parent, lockFilename, &named, AT_SYMLINK_NOFOLLOW) == 0 else { throw OwnershipError.pathChanged }
        try validateFile(opened); try validateFile(named)
        guard opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else { throw OwnershipError.pathChanged }
    }
    private static func verifyDirectoryIdentity(_ parent: Int32, directory: URL) throws {
        let currentParent = try openDirectory(directory, create: false)
        defer { _ = Darwin.close(currentParent) }
        var before = stat(), current = stat()
        guard Darwin.fstat(parent, &before) == 0, Darwin.fstat(currentParent, &current) == 0 else {
            throw OwnershipError.unavailable(errno)
        }
        guard before.st_dev == current.st_dev, before.st_ino == current.st_ino else { throw OwnershipError.pathChanged }
    }
    private static func openDirectory(_ directory: URL, create: Bool) throws -> Int32 {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw OwnershipError.unavailable(errno) }
        do {
            for component in directory.pathComponents where component != "/" {
                var next = Darwin.openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    if Darwin.mkdirat(descriptor, component, 0o700) != 0, errno != EEXIST { throw OwnershipError.unavailable(errno) }
                    next = Darwin.openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else {
                    let code = errno
                    if code == ELOOP || code == ENOTDIR { throw OwnershipError.unsafePath }
                    throw OwnershipError.unavailable(code)
                }
                _ = Darwin.close(descriptor); descriptor = next
            }
            var info = stat()
            guard Darwin.fstat(descriptor, &info) == 0 else { throw OwnershipError.unavailable(errno) }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw OwnershipError.unsafePath }
            guard info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700 else { throw OwnershipError.unsafePermissions }
            return descriptor
        } catch { _ = Darwin.close(descriptor); throw error }
    }
}
