import Foundation
import VibekeyCore

@main enum OnboardActionLibraryChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            checks += 1
        }
        let presets = ActionCatalog.presets
        let copy = presets.first { $0.id == "editing.copy" }!
        let copyShortcut = copy.onboardShortcut!
        check(copyShortcut.keyCode == 8 && copyShortcut.modifiers == 0x100000, "Copy remains Command-C")
        check(try AU05OnboardShortcut.entries(for: copyShortcut) == [.init(page: 3, usage: 8), .init(page: 2, usage: 6)], "Copy uses verified vendor encoding")
        let previous = presets.first { $0.id == "windows.previous-app" }!.onboardShortcut!
        check(try AU05OnboardShortcut.entries(for: previous) == [.init(page: 3, usage: 8), .init(page: 2, usage: 43)], "App switching keeps Command-Tab")
        check(presets.first { $0.id == "windows.rotary-overview" }!.onboardShortcut == nil, "Native app launch stays in Mac library")
        func preset(_ step: WorkflowStep) -> ActionPreset {
            ActionPreset(id: "fixture", title: "fixture", detail: "", category: .system, step: step)
        }
        check(preset(WorkflowStep(kind: .shortcut, keyCode: 40, modifiers: 0x1a0000)).onboardShortcut != nil, "Three modifiers and key fit four entries")
        check(preset(WorkflowStep(kind: .shortcut, keyCode: 40, modifiers: 0x1e0000)).onboardShortcut == nil, "Five entries cannot reach device")
        check(preset(WorkflowStep(kind: .shortcut, keyCode: 63)).onboardShortcut == nil, "Unverified Fn key excluded")
        check(preset(WorkflowStep(kind: .shortcut, keyCode: 8, modifiers: 0x800000)).onboardShortcut == nil, "Unverified Fn chord excluded")
        check(preset(WorkflowStep(kind: .shortcut, keyCode: 255)).onboardShortcut == nil, "Unmapped key excluded")
        check(preset(WorkflowStep(kind: .delay, seconds: 1)).onboardShortcut == nil, "Macro delay is not a keyboard chord")
        check(preset(WorkflowStep(kind: .scrollUp)).onboardShortcut == nil, "Mac scroll settings are not silently reduced to device scroll")
        let supported = presets.compactMap { $0.onboardShortcut }
        check(!supported.isEmpty && supported.count < presets.count, "Native and full libraries have distinct scope")
        for shortcut in supported {
            let value = try AU05OnboardShortcut(index: 1, entries: AU05OnboardShortcut.entries(for: shortcut))
            check(value.recordedShortcut == shortcut, "Every offered shortcut round-trips without loss")
        }
        check(presets.count == 104 && presets.contains { $0.id == "windows.rotary-overview" }, "Full Mac library remains available")
        print("{\"status\":\"PASS\",\"checks\":\(checks),\"nativePresets\":\(supported.count),\"fullPresets\":\(presets.count),\"deviceWrites\":0,\"hostActionsExecuted\":0}")
    }
}
