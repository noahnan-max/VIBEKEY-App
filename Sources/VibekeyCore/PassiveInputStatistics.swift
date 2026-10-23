import Foundation

public enum UsageCountSource: String, Codable { case observed, estimated, unavailable }
public enum InputObservationFailure: String, Error { case permission, unsupported, secure, targetChanged, invalidRange, changedContext, composing, unchanged, timeout, interrupted }

/// Ephemeral input only. This type deliberately has no persistence conformance.
public struct InputFieldSnapshot {
    public let text: String
    public let selection: NSRange
    public let composing: Bool?
    public let selectionKnown: Bool
    public init(text: String, selection: NSRange, composing: Bool? = nil, selectionKnown: Bool = true) {
        self.text = text; self.selection = selection; self.composing = composing; self.selectionKnown = selectionKnown
    }
}

public enum ObservedInputCharacters {
    public static let maximumUTF16 = 50_000
    /// Count the final replacement span, not net document growth or previews.
    public static func count(before: InputFieldSnapshot, after: InputFieldSnapshot) throws -> Int {
        guard before.text.utf16.count <= maximumUTF16, after.text.utf16.count <= maximumUTF16 else { throw InputObservationFailure.invalidRange }
        guard after.composing != true else { throw InputObservationFailure.composing }
        guard !before.text.utf16.elementsEqual(after.text.utf16) else { throw InputObservationFailure.unchanged }
        // Some web editors expose text but no caret range. Count only the final
        // changed span instead of discarding readable text and estimating time.
        if !before.selectionKnown { return changedSpan(before: before.text, after: after.text) }
        guard
              before.selection.location != NSNotFound,
              before.selection.location >= 0, before.selection.length >= 0,
              before.selection.location <= before.text.utf16.count,
              before.selection.length <= before.text.utf16.count - before.selection.location,
              let oldRange = Range(before.selection, in: before.text),
              before.text.indices.contains(oldRange.lowerBound) || oldRange.lowerBound == before.text.endIndex,
              before.text.indices.contains(oldRange.upperBound) || oldRange.upperBound == before.text.endIndex else { throw InputObservationFailure.invalidRange }
        let prefix = String(before.text[..<oldRange.lowerBound]), suffix = String(before.text[oldRange.upperBound...])
        let body = after.text as NSString, prefixLength = prefix.utf16.count, suffixLength = suffix.utf16.count
        guard body.length >= prefixLength + suffixLength,
              body.substring(to: prefixLength).utf16.elementsEqual(prefix.utf16),
              body.substring(from: body.length - suffixLength).utf16.elementsEqual(suffix.utf16) else { throw InputObservationFailure.changedContext }
        let insertedRange = NSRange(location: prefixLength, length: body.length - prefixLength - suffixLength)
        guard let span = Range(insertedRange, in: after.text),
              after.text.indices.contains(span.lowerBound) || span.lowerBound == after.text.endIndex,
              after.text.indices.contains(span.upperBound) || span.upperBound == after.text.endIndex,
              !after.selectionKnown || after.selection == NSRange(location: NSMaxRange(insertedRange), length: 0) else { throw InputObservationFailure.invalidRange }
        return after.text[span].filter { !$0.isWhitespace }.count
    }
    private static func changedSpan(before: String, after: String) -> Int {
        let old = Array(before), new = Array(after)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        return new[prefix..<(new.count - suffix)].filter { !$0.isWhitespace }.count
    }
}

/// Ephemeral streaming state. Count received characters once as they appear;
/// later rewrites/deletions do not subtract, and never accumulate whole drafts.
public struct ReceivedInputCharacters {
    private var baseline: InputFieldSnapshot
    private var previous: InputFieldSnapshot
    private var segmentReceived = 0
    public private(set) var total = 0
    public init(before: InputFieldSnapshot) { baseline = before; previous = before }
    @discardableResult public mutating func receive(_ snapshot: InputFieldSnapshot) throws -> Int {
        guard snapshot.text.utf16.count <= ObservedInputCharacters.maximumUTF16 else { throw InputObservationFailure.invalidRange }
        let current = InputFieldSnapshot(text: snapshot.text, selection: snapshot.selection, composing: false, selectionKnown: snapshot.selectionKnown)
        if previous.text.utf16.elementsEqual(current.text.utf16) { previous = current; return total }
        if current.text.isEmpty || current.text.utf16.elementsEqual(baseline.text.utf16) {
            baseline = current; previous = current; segmentReceived = 0; return total
        }
        let addition: Int
        if previous.selectionKnown, let inserted = try? ObservedInputCharacters.count(before: previous, after: current) {
            addition = inserted
        } else if current.text.hasPrefix(previous.text) {
            addition = current.text.dropFirst(previous.text.count).filter { !$0.isWhitespace }.count
        } else {
            // An ASR rewrite can replace the entire interim span. Only growth
            // beyond this segment's already received amount is additional input.
            let textOnly = InputFieldSnapshot(text: current.text, selection: current.selection, selectionKnown: false)
            let span = try ObservedInputCharacters.count(before: baseline, after: textOnly)
            addition = max(0, span - segmentReceived)
        }
        segmentReceived += addition; total = min(100_000, total + addition); previous = current
        return total
    }
}

public struct UsageStatisticsPreferences: Codable, Equatable {
    public var enabled = false
    public var observationConsentVersion: Int?
    public var estimateWhenUnavailable = true
    public var spokenCharactersPerMinute = 180
    public var typingCharactersPerMinute = 60
    public init() {}
    /// Legacy automatic defaults do not grant a new text-observation purpose.
    public var collectionEnabled: Bool { enabled && observationConsentVersion == 1 }
    public var isValid: Bool {
        (60...500).contains(spokenCharactersPerMinute) && (10...500).contains(typingCharactersPerMinute)
            && (observationConsentVersion == nil || observationConsentVersion == 1)
    }
}

public struct UsageStatisticsDay: Codable, Equatable {
    public var observedCharacters = 0
    public var estimatedCharacters = 0
    public var observedSessions = 0
    public var estimatedSessions = 0
    public var unavailableSessions = 0
    public var operationSeconds: Double = 0
    public var countedOperationSeconds: Double = 0
    public var observationFailures: [String: Int]?
    public init() {}
    public var totalCharacters: Int { observedCharacters + estimatedCharacters }
    public var sessions: Int { observedSessions + estimatedSessions + unavailableSessions }
    public var hasCharacterCoverage: Bool { observedSessions + estimatedSessions > 0 }
    public var isValid: Bool {
        [observedCharacters, estimatedCharacters, observedSessions, estimatedSessions, unavailableSessions].allSatisfy { (0...100_000_000).contains($0) } &&
        operationSeconds.isFinite && operationSeconds >= 0 && operationSeconds <= 100_000_000 &&
        countedOperationSeconds.isFinite && countedOperationSeconds >= 0 && countedOperationSeconds <= operationSeconds &&
        (observationFailures?.count ?? 0) <= 32 &&
        (observationFailures?.allSatisfy { $0.key.count <= 32 && (0...100_000_000).contains($0.value) } ?? true)
    }
}

public struct UsageStatisticsLedger: Codable, Equatable {
    public var schemaVersion = 1
    public var preferences = UsageStatisticsPreferences()
    public var startedAt: Date?
    public var days: [String: UsageStatisticsDay] = [:]
    public init() {}
    public var isValid: Bool {
        schemaVersion == 1 && preferences.isValid && days.count <= 30_000 && days.allSatisfy { day, value in
            day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil && value.isValid
        }
    }
    public mutating func record(at: Date, seconds: Double, characters: Int?, source: UsageCountSource, failure: InputObservationFailure? = nil, calendar: Calendar = .current) {
        guard seconds.isFinite, (0...600).contains(seconds), characters.map({ (0...100_000).contains($0) }) ?? true else { return }
        let key = Self.dayKey(at, calendar: calendar)
        var day = days[key] ?? UsageStatisticsDay()
        if let failure { var reasons = day.observationFailures ?? [:]; reasons[failure.rawValue, default: 0] += 1; day.observationFailures = reasons }
        day.operationSeconds += seconds
        switch source {
        case .observed: day.observedCharacters += characters ?? 0; day.observedSessions += 1; day.countedOperationSeconds += seconds
        case .estimated: day.estimatedCharacters += characters ?? 0; day.estimatedSessions += 1; day.countedOperationSeconds += seconds
        case .unavailable: day.unavailableSessions += 1
        }
        days[key] = day
    }
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    public var totals: UsageStatisticsDay {
        days.values.reduce(into: UsageStatisticsDay()) { sum, day in
            sum.observedCharacters += day.observedCharacters; sum.estimatedCharacters += day.estimatedCharacters
            sum.observedSessions += day.observedSessions; sum.estimatedSessions += day.estimatedSessions
            sum.unavailableSessions += day.unavailableSessions; sum.operationSeconds += day.operationSeconds; sum.countedOperationSeconds += day.countedOperationSeconds
            if let reasons = day.observationFailures {
                var combined = sum.observationFailures ?? [:]
                for (reason, count) in reasons { combined[reason, default: 0] += count }; sum.observationFailures = combined
            }
        }
    }
    public func streaks(now: Date = Date(), calendar: Calendar = .current) -> (active: Int, current: Int, longest: Int) {
        let activeKeys = Set(days.filter { $0.value.totalCharacters > 0 }.map(\.key))
        var longest = 0, run = 0, previous: Date?
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        for key in activeKeys.sorted() {
            guard let date = formatter.date(from: key) else { continue }
            run = previous.flatMap { calendar.dateComponents([.day], from: $0, to: date).day } == 1 ? run + 1 : 1
            longest = max(longest, run); previous = date
        }
        var current = 0, day = calendar.startOfDay(for: now)
        if !activeKeys.contains(Self.dayKey(day, calendar: calendar)), let yesterday = calendar.date(byAdding: .day, value: -1, to: day) { day = yesterday }
        while activeKeys.contains(Self.dayKey(day, calendar: calendar)) {
            current += 1
            guard let before = calendar.date(byAdding: .day, value: -1, to: day) else { break }; day = before
        }
        return (activeKeys.count, current, longest)
    }
}

public enum UsageStatisticsFile {
    public static func load(directory: URL) throws -> UsageStatisticsLedger {
        try validate(directory)
        let file = directory.appendingPathComponent("usage.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return UsageStatisticsLedger() }
        try validate(file)
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 2 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let ledger = try JSONDecoder().decode(UsageStatisticsLedger.self, from: Data(contentsOf: file))
        guard ledger.isValid else { throw CocoaError(.fileReadCorruptFile) }; return ledger
    }
    public static func save(_ ledger: UsageStatisticsLedger, directory: URL) throws {
        guard ledger.isValid else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        try validate(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("usage.json"); try validate(file)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(ledger).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private static func validate(_ url: URL) throws {
        guard url.isFileURL, (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw CocoaError(.fileReadNoPermission) }
        if FileManager.default.fileExists(atPath: url.path) {
            let a = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  ((a[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0 else { throw CocoaError(.fileReadNoPermission) }
        }
    }
}
