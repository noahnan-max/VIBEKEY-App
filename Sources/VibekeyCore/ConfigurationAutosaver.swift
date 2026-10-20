import Foundation

/// A main-queue coalescer. It never runs at initialization; callers schedule it
/// only for an actual user edit, and can flush before navigation or shutdown.
@MainActor public final class ConfigurationAutosaver {
    private let delay: TimeInterval
    private let commit: @MainActor () -> Void
    private var work: Task<Void, Never>?
    private var revision: UInt64 = 0
    public private(set) var isPending = false

    public init(delay: TimeInterval = 0.35, commit: @escaping @MainActor () -> Void) {
        self.delay = delay; self.commit = commit
    }
    public func schedule() {
        cancel(); isPending = true
        let expected = revision
        let next = Task { [weak self, delay] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000)) }
            catch { return }
            guard let self, self.revision == expected, self.isPending else { return }
            self.work = nil; self.isPending = false; self.commit()
        }
        work = next
    }
    public func flush() {
        guard isPending else { return }
        cancel(); commit()
    }
    public func cancel() {
        revision &+= 1; work?.cancel(); work = nil; isPending = false
    }
    deinit { work?.cancel() }
}
