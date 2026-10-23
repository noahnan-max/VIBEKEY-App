import AppKit
import ApplicationServices
import VibekeyCore

/// A bounded reader adapted from the former CursorCorrectionReader. No writer,
/// focus activation, keyboard tap, pasteboard or microphone is owned here.
final class PassiveInputObserver {
    struct Reader {
        let before: InputFieldSnapshot
        let read: () throws -> InputFieldSnapshot
    }
    struct Receipt {
        let id: UUID
        let startedAt: Date
        let seconds: Double
        let characters: Int?
        let failure: InputObservationFailure?
    }
    struct Progress {
        let id: UUID
        let characters: Int?
        let failure: InputObservationFailure?
    }
    private final class Session {
        let id: UUID, at: Date, uptime: Double
        var reader: Reader?
        var failure: InputObservationFailure?
        var ended: Double?
        var received: ReceivedInputCharacters?
        var changedAt: Double = 0
        var lastPublishedCharacters: Int?
        var lastPublishedFailure: InputObservationFailure?
        init(id: UUID, at: Date, uptime: Double) { self.id = id; self.at = at; self.uptime = uptime }
    }
    private let queue = DispatchQueue(label: "local.noah.vibekey.passive-input", qos: .utility)
    private let readerFactory: (pid_t) throws -> Reader
    private let completed: (Receipt) -> Void
    private let progressed: (Progress) -> Void
    private let settleSeconds: Double
    private var session: Session?
    private var primed: (reader: Reader, at: Double)?
    init(settleSeconds: Double = 12, readerFactory: @escaping (pid_t) throws -> Reader = PassiveInputObserver.capture,
         progressed: @escaping (Progress) -> Void = { _ in }, completed: @escaping (Receipt) -> Void) {
        self.readerFactory = readerFactory; self.completed = completed; self.progressed = progressed; self.settleSeconds = settleSeconds
    }
    /// Any AU05 press may freeze the original field before a voice overlay takes
    /// focus. It never starts a statistic; unconfirmed snapshots expire in 3s.
    func prime(pid: pid_t) {
        queue.async { [weak self] in
            guard let self, session == nil else { return }
            let at = ProcessInfo.processInfo.systemUptime
            guard let reader = try? readerFactory(pid), ProcessInfo.processInfo.systemUptime - at <= 0.25 else { return }
            primed = (reader, at)
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, primed?.at == at else { return }; primed = nil
            }
        }
    }
    func begin(id: UUID, at: Date, uptime: Double, pid: pid_t) {
        queue.async { [weak self] in
            guard let self else { return }
            if let old = session {
                // A new recording can start before the previous quiet window
                // expires. Close the old span against the current field before
                // freezing the new baseline, so the two never overlap.
                if old.ended != nil { read(old) }
                else { old.failure = .interrupted }
                complete(old)
            }
            let next = Session(id: id, at: at, uptime: uptime); session = next
            do {
                let started = ProcessInfo.processInfo.systemUptime
                if let prepared = primed, started - prepared.at <= 3 { next.reader = prepared.reader }
                else { next.reader = try readerFactory(pid) }
                primed = nil
                if ProcessInfo.processInfo.systemUptime - started > 0.25 { next.reader = nil; next.failure = .timeout }
            } catch { next.failure = error as? InputObservationFailure ?? .unsupported }
            if let reader = next.reader { next.received = ReceivedInputCharacters(before: reader.before) }
            publish(next); sampleLater(next)
            queue.asyncAfter(deadline: .now() + 600) { [weak self, weak next] in
                guard let self, let next, session === next else { return }
                next.ended = ProcessInfo.processInfo.systemUptime; next.failure = next.failure ?? .timeout; complete(next)
            }
        }
    }
    func end(id: UUID, uptime: Double) {
        queue.async { [weak self] in
            guard let self, let current = session, current.id == id, current.ended == nil else { return }
            current.ended = uptime
            if current.reader == nil { complete(current) }
        }
    }
    func cancel() { queue.async { [weak self] in self?.session = nil; self?.primed = nil } }
    private func sampleLater(_ current: Session) {
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self, weak current] in
            guard let self, let current, session === current else { return }
            let now = ProcessInfo.processInfo.systemUptime
            read(current); publish(current)
            if let end = current.ended,
               (now - end >= 1.5 && (current.received?.total ?? 0) > 0 && now - current.changedAt >= 0.8 || now - end >= settleSeconds) {
                complete(current)
            } else { sampleLater(current) }
        }
    }
    private func read(_ current: Session) {
        guard let reader = current.reader, current.failure != .secure else { return }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let value = try reader.read()
            guard ProcessInfo.processInfo.systemUptime - started <= 0.25 else { current.failure = .timeout; return }
            let before = current.received?.total ?? 0
            let after = try current.received?.receive(value) ?? 0
            current.failure = nil
            if after != before { current.changedAt = ProcessInfo.processInfo.systemUptime }
        } catch { current.failure = error as? InputObservationFailure ?? .unsupported }
        // A temporary overlay/focus change is retried only against this frozen
        // field. It neither redirects observation nor stops normal input.
    }
    private func publish(_ current: Session) {
        let count = current.received?.total
        guard count != current.lastPublishedCharacters || current.failure != current.lastPublishedFailure else { return }
        current.lastPublishedCharacters = count; current.lastPublishedFailure = current.failure
        let value = Progress(id: current.id, characters: count, failure: current.failure)
        DispatchQueue.main.async { [progressed] in progressed(value) }
    }
    private func complete(_ current: Session) {
        let received = current.received?.total ?? 0
        let characters: Int? = received > 0 ? received : (current.reader != nil && current.failure == nil ? 0 : nil)
        finish(current, characters: characters, failure: current.failure)
    }
    private func finish(_ current: Session, characters: Int?, failure: InputObservationFailure?) {
        guard session === current else { return }
        session = nil
        let receipt = Receipt(id: current.id, startedAt: current.at,
            seconds: min(600, max(0, (current.ended ?? ProcessInfo.processInfo.systemUptime) - current.uptime)), characters: characters, failure: failure)
        DispatchQueue.main.async { [completed] in completed(receipt) }
    }
    static func capture(pid: pid_t) throws -> Reader {
        guard AXIsProcessTrusted() else { throw InputObservationFailure.permission }
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw InputObservationFailure.targetChanged }
        let root = AXUIElementCreateApplication(pid)
        guard let field = element(root, kAXFocusedUIElementAttribute) else { throw InputObservationFailure.unsupported }
        try validateField(field)
        let before = try snapshot(field)
        let read: () throws -> InputFieldSnapshot = {
            guard AXIsProcessTrusted(), !app.isTerminated,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let focused = element(root, kAXFocusedUIElementAttribute), CFEqual(focused, field) else { throw InputObservationFailure.targetChanged }
            try validateField(field)
            let value = try snapshot(field)
            guard let final = element(root, kAXFocusedUIElementAttribute), CFEqual(final, field) else { throw InputObservationFailure.targetChanged }
            return value
        }
        return Reader(before: before, read: read)
    }
    private static func validateField(_ field: AXUIElement) throws {
        if value(field, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { throw InputObservationFailure.secure }
        guard let role = value(field, kAXRoleAttribute) as? String,
              [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role) else { throw InputObservationFailure.unsupported }
    }
    private static func snapshot(_ field: AXUIElement) throws -> InputFieldSnapshot {
        if let length = value(field, kAXNumberOfCharactersAttribute) as? NSNumber,
           length.intValue > ObservedInputCharacters.maximumUTF16 { throw InputObservationFailure.unsupported }
        let length = (value(field, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
        var text = value(field, kAXValueAttribute) as? String
        if text == nil, let length, (0...ObservedInputCharacters.maximumUTF16).contains(length) {
            var span = CFRange(location: 0, length: length)
            if let parameter = AXValueCreate(.cfRange, &span) {
                var raw: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString, parameter, &raw) == .success { text = raw as? String }
            }
        }
        guard let text, text.utf16.count <= ObservedInputCharacters.maximumUTF16 else { throw InputObservationFailure.unsupported }
        let selection = range(value(field, kAXSelectedTextRangeAttribute))
        let marked = range(value(field, "AXMarkedTextRange"))
        let composing = marked.map { $0.location != NSNotFound && $0.length > 0 }
        return InputFieldSnapshot(text: text, selection: selection ?? NSRange(location: 0, length: 0), composing: composing, selectionKnown: selection != nil)
    }
    private static func range(_ raw: CFTypeRef?) -> NSRange? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var r = CFRange(); guard AXValueGetValue(raw as! AXValue, .cfRange, &r) else { return nil }
        return NSRange(location: r.location, length: r.length)
    }
    private static func element(_ root: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = value(root, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }
    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        // Per-client messaging timeout, never a target application attribute write.
        AXUIElementSetMessagingTimeout(element, 0.06)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
}
