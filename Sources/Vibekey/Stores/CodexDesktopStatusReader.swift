import Foundation
import Darwin
import VibekeyCore

/// Read-only, version-pinned compatibility reader. The caller serializes poll.
/// No source files, raw records, prompts, messages or tool payloads are written.
final class CodexDesktopStatusReader: CodexDesktopStatusReading, @unchecked Sendable {
    private static let maximumCandidates = 64
    private static let maximumHeaderBytes = 128 * 1024
    private static let maximumLineBytes = 2 * 1024 * 1024
    private static let maximumBatchBytes = 16 * 1024 * 1024
    private static let maximumSessionBytes = 4 * 1024 * 1024
    private static let maximumFileBytes = 128 * 1024 * 1024
    // The native bridge retains at most 16 pending requests per session.
    private static let maximumClosuresPerSession = 16
    private struct Terminal {
        let metadata: CodexDesktopEventMetadata
        let state: AgentSignalState
    }
    private struct Cursor {
        let url: URL
        let device: dev_t
        let inode: ino_t
        let base: String
        var offset: UInt64 = 0
        var remainder = Data()
        var baseline = true
        var rejected = false
        var epoch: Int?
        var activeTurn: String?
        var latestActivity: CodexDesktopEventMetadata?
        var latestTime: TimeInterval = 0
        var terminalTurn: String?
        var terminalState: AgentSignalState?
        var terminals: [Terminal] = []
        var deferred: [CodexDesktopEventMetadata] = []
    }
    private struct EpochFile: Decodable { let schemaVersion: Int; let sessions: [String: Epoch] }
    private struct Epoch: Decodable { let epoch: Int }
    private enum ReadError: Error { case unsafe, invalid, capacity }
    private let sessionsRoot: URL
    private let bridgeDirectory: URL
    private var cursors: [String: Cursor] = [:]
    private var latest: [String: AgentSignal] = [:]
    private var closures: [String: [String: CodexDesktopTurnClosure]] = [:]
    private var sequence: UInt64 = 0
    private var lastPoll: TimeInterval?
    private var rollbackUntil: TimeInterval?

    init(sessionsRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions", isDirectory: true),
         bridgeDirectory: URL = VibekeyPaths.applicationSupport.appendingPathComponent("AgentSignals", isDirectory: true)) {
        self.sessionsRoot = sessionsRoot.standardizedFileURL
        self.bridgeDirectory = bridgeDirectory.standardizedFileURL
    }

    func poll(at now: Date) throws -> CodexDesktopStatusBatch {
        let time = now.timeIntervalSince1970
        guard time.isFinite, time > 0 else { return unavailable(now, "系统时间不可用，Codex 状态未知。") }
        if let prior = lastPoll, time < prior {
            rollbackUntil = max(rollbackUntil ?? prior, prior); clearSource()
        }
        lastPoll = time
        if let until = rollbackUntil {
            guard time >= until else { return unavailable(now, "系统时间已变化，等待新的 Codex 状态。") }
            rollbackUntil = nil
        }
        do {
            try checkDirectory(sessionsRoot, privateMode: false)
            let epochs = try readEpochs()
            let candidates = try candidateFiles(at: now)
            let retained = Set(candidates.map(\.path))
            for (path, cursor) in cursors where !retained.contains(path) {
                cursors.removeValue(forKey: path); latest.removeValue(forKey: cursor.base); closures.removeValue(forKey: cursor.base)
            }
            var inspected = 0, available = 0, remaining = Self.maximumBatchBytes
            for url in candidates {
                guard remaining > 0 else { break }
                let path = url.path
                var attemptedBase: String?
                var countedAvailable = false
                do {
                    let (handle, info) = try openFile(url, maximum: Self.maximumFileBytes, privateMode: false)
                    defer { try? handle.close() }
                    var cursor: Cursor
                    if let prior = cursors[path], prior.device == info.st_dev, prior.inode == info.st_ino,
                       UInt64(info.st_size) >= prior.offset {
                        cursor = prior
                    } else {
                        if let prior = cursors.removeValue(forKey: path) {
                            latest.removeValue(forKey: prior.base); closures.removeValue(forKey: prior.base)
                        }
                        let headerBytes = try handle.read(upToCount: Self.maximumHeaderBytes) ?? Data()
                        remaining -= headerBytes.count
                        guard let newline = headerBytes.firstIndex(of: 10),
                              let header = try CodexDesktopStatusDecoder.header(from: headerBytes[..<newline]) else { continue }
                        let base = CodexDesktopStatusIdentity.digest("codex", header.sessionID, "")
                        cursor = Cursor(url: url, device: info.st_dev, inode: info.st_ino, base: base)
                        try handle.seek(toOffset: 0)
                    }
                    inspected += 1
                    if cursor.rejected { cursors[path] = cursor; continue }
                    attemptedBase = cursor.base
                    available += 1; countedAvailable = true
                    let epoch = epochs[cursor.base]?.epoch
                    if cursor.epoch != epoch {
                        // A previously bound proof belongs to that precise
                        // epoch. It cannot be rehashed into a resumed session.
                        if cursor.epoch != nil { cursor.terminals.removeAll() }
                        cursor.epoch = epoch; latest.removeValue(forKey: cursor.base)
                        closures.removeValue(forKey: cursor.base)
                        // An epoch changes only the identity of future evidence.
                        // Existing old terminal records must never be replayed.
                    }
                    var pending: [CodexDesktopEventMetadata] = []
                    for metadata in cursor.deferred {
                        if metadata.occurredAt <= time { try consume(metadata, cursor: &cursor, now: time) }
                        else { pending.append(metadata) }
                    }
                    cursor.deferred = pending
                    try handle.seek(toOffset: cursor.offset)
                    let budget = max(0, min(remaining, Self.maximumSessionBytes, Int(info.st_size) - Int(cursor.offset)))
                    let bytes = try handle.read(upToCount: budget) ?? Data()
                    remaining -= bytes.count; cursor.offset += UInt64(bytes.count)
                    cursor.remainder.append(bytes)
                    var start = cursor.remainder.startIndex
                    while let end = cursor.remainder[start...].firstIndex(of: 10) {
                        let line = cursor.remainder[start..<end]
                        guard line.count <= Self.maximumLineBytes else { throw ReadError.capacity }
                        if !line.isEmpty, let metadata = try CodexDesktopStatusDecoder.event(from: Data(line)) {
                            if metadata.occurredAt > time {
                                // A record can be written while this poll reads
                                // its snapshot. Hold only typed metadata until
                                // the next poll; never publish a future event.
                                guard metadata.occurredAt - time <= 2, cursor.deferred.count < 128 else { throw ReadError.invalid }
                                cursor.deferred.append(metadata)
                            } else { try consume(metadata, cursor: &cursor, now: time) }
                        }
                        start = cursor.remainder.index(after: end)
                    }
                    cursor.remainder = Data(cursor.remainder[start...])
                    guard cursor.remainder.count <= Self.maximumLineBytes else { throw ReadError.capacity }
                    var named = stat()
                    guard lstat(path, &named) == 0, named.st_dev == info.st_dev, named.st_ino == info.st_ino else { throw ReadError.unsafe }
                    let caughtUp = cursor.offset >= UInt64(named.st_size)
                    if caughtUp, cursor.remainder.isEmpty, cursor.deferred.isEmpty, cursor.baseline {
                        cursor.baseline = false
                        // Bootstrap may show only a recent, still-active turn.
                        // A historical end is never an end notification.
                        if let metadata = cursor.latestActivity, cursor.activeTurn != nil {
                            publish(metadata, cursor: cursor, state: .running, endsTurn: false, now: time)
                        }
                    } else if caughtUp, !cursor.baseline, latest[cursor.base] == nil,
                              let metadata = cursor.latestActivity, cursor.activeTurn != nil {
                        // A hook's epoch may have arrived after the first scan.
                        publish(metadata, cursor: cursor, state: .running, endsTurn: false, now: time)
                    }
                    rebuildClosures(for: cursor)
                    cursors[path] = cursor
                } catch {
                    if countedAvailable { available -= 1 }
                    if let base = attemptedBase { latest.removeValue(forKey: base); closures.removeValue(forKey: base) }
                    if var cursor = cursors[path] {
                        cursor.rejected = true; cursor.activeTurn = nil; cursor.remainder.removeAll(keepingCapacity: false)
                        cursor.terminals.removeAll()
                        cursors[path] = cursor; latest.removeValue(forKey: cursor.base); closures.removeValue(forKey: cursor.base)
                    }
                    // No raw error, path, line, message or payload is exposed.
                }
            }
            latest = latest.filter { _, event in
                let age = time - event.occurredAt
                return age >= 0 && age < (event.endsTurn ? 8 : AgentSignalState.running.lifetime)
            }
            let events = latest.values.sorted { $0.occurredAt == $1.occurredAt ? $0.sequence < $1.sequence : $0.occurredAt < $1.occurredAt }
            let closedTurns = closures.values.flatMap { Array($0.values) }.sorted {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
                if $0.sessionHash != $1.sessionHash { return $0.sessionHash < $1.sessionHash }
                return $0.turnHash < $1.turnHash
            }
            let text = available == 0 ? "等待受支持的 Codex Desktop 状态。" : "Codex Desktop 状态已接入；审批由本地 hook 提供。"
            return .init(events: events, observedAt: now, sourceAvailable: available > 0, inspectedSessions: inspected, statusText: text, closedTurns: closedTurns)
        } catch {
            clearSource()
            return unavailable(now, "Codex Desktop 状态源暂不可用。")
        }
    }

    private func consume(_ metadata: CodexDesktopEventMetadata, cursor: inout Cursor, now: TimeInterval) throws {
        guard metadata.occurredAt <= now else { throw ReadError.invalid }
        // Stale/out-of-order records cannot roll a session back into an old turn.
        guard metadata.occurredAt >= cursor.latestTime else { return }
        cursor.latestTime = metadata.occurredAt
        switch metadata.kind {
        case .started:
            guard metadata.turnID != cursor.terminalTurn,
                  !cursor.terminals.contains(where: { $0.metadata.turnID == metadata.turnID }) else { return }
            cursor.activeTurn = metadata.turnID; cursor.latestActivity = metadata
            if !cursor.baseline { publish(metadata, cursor: cursor, state: .running, endsTurn: false, now: now) }
        case .itemCompleted, .tokenCount:
            guard cursor.activeTurn != nil,
                  metadata.turnID == nil || metadata.turnID == cursor.activeTurn else { return }
            cursor.latestActivity = metadata
            if !cursor.baseline { publish(metadata, cursor: cursor, state: .running, endsTurn: false, now: now) }
        case .completed, .aborted:
            guard cursor.activeTurn == nil || cursor.activeTurn == metadata.turnID else { return }
            let state: AgentSignalState = metadata.kind == .aborted ? .interrupted : (metadata.hasError ? .failed : .turnCompleted)
            if let previous = cursor.terminals.first(where: { $0.metadata.turnID == metadata.turnID }) {
                guard previous.state == .turnCompleted && state != .turnCompleted else { return }
            }
            if cursor.terminalTurn == metadata.turnID {
                guard cursor.terminalState == .turnCompleted && state != .turnCompleted else { return }
            }
            if !cursor.baseline {
                publish(metadata, cursor: cursor, state: state, endsTurn: true, now: now)
            }
            cursor.terminalTurn = metadata.turnID; cursor.terminalState = state
            cursor.terminals.removeAll(where: { $0.metadata.turnID == metadata.turnID })
            cursor.terminals.append(Terminal(metadata: metadata, state: state))
            if cursor.terminals.count > Self.maximumClosuresPerSession {
                cursor.terminals.removeFirst(cursor.terminals.count - Self.maximumClosuresPerSession)
            }
            cursor.activeTurn = nil; cursor.latestActivity = nil
        }
    }

    private func rebuildClosures(for cursor: Cursor) {
        guard let epoch = cursor.epoch else { closures.removeValue(forKey: cursor.base); return }
        var proofs: [String: CodexDesktopTurnClosure] = [:]
        for terminal in cursor.terminals {
            guard let turn = terminal.metadata.turnID else { continue }
            let proof = CodexDesktopTurnClosure(
                sessionHash: CodexDesktopStatusIdentity.digest(cursor.base, String(epoch)),
                turnHash: CodexDesktopStatusIdentity.digest("codex", cursor.base, turn),
                occurredAt: terminal.metadata.occurredAt, state: terminal.state)
            guard (try? proof.validate()) != nil else { continue }
            proofs[proof.turnHash] = proof
        }
        closures[cursor.base] = proofs
    }

    private func publish(_ metadata: CodexDesktopEventMetadata, cursor: Cursor, state: AgentSignalState,
                         endsTurn: Bool, now: TimeInterval) {
        guard let epoch = cursor.epoch, let turn = metadata.turnID ?? cursor.activeTurn,
              now - metadata.occurredAt >= 0, now - metadata.occurredAt < (endsTurn ? 8 : AgentSignalState.running.lifetime) else { return }
        sequence &+= 1
        let turnHash = CodexDesktopStatusIdentity.digest("codex", cursor.base, turn)
        let event = AgentSignal(source: .codex, state: state,
            sessionHash: CodexDesktopStatusIdentity.digest(cursor.base, String(epoch)),
            eventID: CodexDesktopStatusIdentity.digest("codex-desktop-metadata-v1", cursor.base, String(epoch), metadata.kind.rawValue,
                turnHash, String(metadata.occurredAt), state.rawValue),
            sequence: sequence, occurredAt: metadata.occurredAt, turnHash: turnHash, endsTurn: endsTurn)
        latest[cursor.base] = event
    }

    private func clearSource() { cursors.removeAll(); latest.removeAll(); closures.removeAll() }
    private func unavailable(_ now: Date, _ message: String) -> CodexDesktopStatusBatch {
        .init(events: [], observedAt: now, sourceAvailable: false, inspectedSessions: 0, statusText: message)
    }

    private func readEpochs() throws -> [String: Epoch] {
        var directory = stat()
        if lstat(bridgeDirectory.path, &directory) != 0 {
            if errno == ENOENT { return [:] }; throw ReadError.unsafe
        }
        try checkDirectory(bridgeDirectory, privateMode: true)
        let path = bridgeDirectory.appendingPathComponent("state.json")
        if !FileManager.default.fileExists(atPath: path.path) { return [:] }
        let (handle, info) = try openFile(path, maximum: 2 * 1024 * 1024, privateMode: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 2 * 1024 * 1024 else { throw ReadError.capacity }
        let state = try JSONDecoder().decode(EpochFile.self, from: data)
        var named = stat()
        guard lstat(path.path, &named) == 0, named.st_dev == info.st_dev, named.st_ino == info.st_ino else { throw ReadError.unsafe }
        guard state.schemaVersion == 1, state.sessions.count <= 4096,
              state.sessions.allSatisfy({ key, value in
                  key.utf8.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                  && value.epoch >= 0 && value.epoch <= 9_007_199_254_740_991
              }) else { throw ReadError.invalid }
        return state.sessions
    }

    private func candidateFiles(at now: Date) throws -> [URL] {
        let calendar = Calendar.current
        let dates = [now, calendar.date(byAdding: .day, value: -1, to: now)!]
        var files: [(URL, TimeInterval)] = []
        for day in dates {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let path = sessionsRoot.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!), isDirectory: true)
            if !FileManager.default.fileExists(atPath: path.path) { continue }
            try checkDirectory(path, privateMode: false)
            let urls = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            guard urls.count <= 4096 else { throw ReadError.capacity }
            for url in urls where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
                files.append((url, values.contentModificationDate?.timeIntervalSince1970 ?? 0))
            }
        }
        return files.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }.prefix(Self.maximumCandidates).map(\.0)
    }

    private func checkAncestors(_ url: URL) throws {
        var current = url
        while true {
            var info = stat()
            guard lstat(current.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else { throw ReadError.unsafe }
            if current.path == "/" { break }
            current.deleteLastPathComponent()
        }
    }
    private func checkDirectory(_ url: URL, privateMode: Bool) throws {
        try checkAncestors(url)
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
              privateMode ? (info.st_mode & 0o777) == 0o700 : (info.st_mode & 0o022) == 0 else { throw ReadError.unsafe }
    }
    private func openFile(_ url: URL, maximum: Int, privateMode: Bool) throws -> (FileHandle, stat) {
        try checkAncestors(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ReadError.unsafe }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= maximum,
              privateMode ? (info.st_mode & 0o777) == 0o600 : (info.st_mode & 0o022) == 0 else { close(fd); throw ReadError.unsafe }
        return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), info)
    }
}
