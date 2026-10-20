import Foundation

/// VIBEKEY's own base mapping; legacy passthrough is only a storage adapter.
public enum AU05ActionDefaults {
    public static let scrollLines = 3
    public static let scrollRange = 1...50
    public static func displayed(_ step: WorkflowStep, triggerID: String) -> WorkflowStep {
        guard step.kind == .passthrough else { return step }
        var value = step; value.argument = ""; value.modifiers = 0
        switch triggerID {
        case "key.0": value.kind = .shortcut; value.keyCode = 59
        case "key.1": value.kind = .shortcut; value.keyCode = 36
        case "key.2": value.kind = .shortcut; value.keyCode = 51
        case "knob.press": value.kind = .shortcut; value.keyCode = 62
        case "knob.left": value.kind = .scrollUp; value.scrollLines = scrollLines
        case "knob.right": value.kind = .scrollDown; value.scrollLines = scrollLines
        default: return step
        }
        return value
    }
}
