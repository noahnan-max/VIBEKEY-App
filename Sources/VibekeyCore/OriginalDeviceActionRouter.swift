/// Events for the caller's system-event sink. Modifiers describe only the
/// Control keys held by this router; no event is posted by this type.
public enum OriginalDeviceActionEvent: Equatable {
    case key(keyCode: UInt16, pressed: Bool, modifiers: UInt64)
    case scroll(lines: Int32, modifiers: UInt64)
}

/// Preserves the user's six original AU05 actions independently of custom macros.
/// Feed every recognized press/release through the same owner. On disconnect, shutdown or an ownership change, deliver releaseAll().
public struct OriginalDeviceActionRouter {
    private var heldKeys: Set<UInt16> = []

    public init() {}

    public var currentModifiers: UInt64 { modifiers }
    public mutating func handle(_ id: String, pressed: Bool, scrollLines: Int32 = 1) -> [OriginalDeviceActionEvent] {
        if id == "knob.left" || id == "knob.right" {
            guard pressed, (1...50).contains(scrollLines) else { return [] }
            return [.scroll(lines: id == "knob.left" ? scrollLines : -scrollLines, modifiers: modifiers)]
        }
        let keyCode: UInt16
        switch id {
        case "key.0": keyCode = 59
        case "key.1": keyCode = 36
        case "key.2": keyCode = 51
        case "knob.press": keyCode = 62
        default: return []
        }
        if pressed {
            guard !heldKeys.contains(keyCode) else { return [] }
            heldKeys.insert(keyCode)
            return [.key(keyCode: keyCode, pressed: true, modifiers: modifiers)]
        }
        guard heldKeys.remove(keyCode) != nil else { return [] }
        // The owner of the down also owns the up, even if the configuration changed.
        return [.key(keyCode: keyCode, pressed: false, modifiers: modifiers)]
    }

    public mutating func releaseAll() -> [OriginalDeviceActionEvent] {
        var events: [OriginalDeviceActionEvent] = []
        // Release ordinary keys before modifiers, then clear the remaining flags.
        for keyCode in heldKeys.sorted() {
            heldKeys.remove(keyCode)
            events.append(.key(keyCode: keyCode, pressed: false, modifiers: modifiers))
        }
        return events
    }

    private var modifiers: UInt64 {
        var flags: UInt64 = 0
        if heldKeys.contains(59) { flags |= 0x00040000 | 0x00000001 }
        if heldKeys.contains(62) { flags |= 0x00040000 | 0x00002000 }
        return flags
    }
}
