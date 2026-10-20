import Foundation
import VibekeyCore

@main enum WindowOverviewChecks {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
        func target(_ id: UInt32, _ x: CGFloat = 0, _ y: CGFloat = 0) -> WindowOverviewTarget {
            .init(id: id, frame: CGRect(x: x, y: y, width: 200, height: 120))
        }
        let a = target(1), b = target(2, 250), c = target(3, 0, 200)
        var selection = WindowOverviewSelection()
        selection.begin([c, b, a])
        check(selection.targets.map(\.id) == [1, 2, 3], "Visual ordering")
        check(selection.selectedID == 1, "First target selected")
        check(selection.rotate(1, current: [a, b, c])?.id == 2, "Next window")
        check(selection.rotate(2, current: [a, b, c])?.id == 1, "Wrap forward")
        check(selection.rotate(-1, current: [a, b, c])?.id == 3, "Wrap backward")
        check(selection.resolve(3, current: [c, b, a]) == c, "Confirm identity after reorder")
        check(selection.resolve(2, current: [a, b, c]) == nil, "Reject different identity")
        check(selection.resolve(3, current: [a, b]) == nil, "Closed window not replaced by another")
        check(selection.resolve(3, current: [a, c, c]) == nil, "Ambiguous identity rejected")
        selection.begin([a, a, b, target(0)])
        check(selection.targets == [b], "Ambiguous and invalid targets excluded")
        check(!WindowOverviewTarget(id: 8, frame: .zero).isValid, "Tiny system buttons excluded")
        check(!WindowOverviewTarget(id: 8, frame: CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100)).isValid, "Non-finite geometry excluded")
        selection.end(); check(selection.targets.isEmpty && selection.selectedID == nil, "Session data cleared")
        check(WindowOverviewAction.matches([WindowOverviewAction.step]), "Recognizes the system application")
        check(!WindowOverviewAction.matches([.init(kind: .openApp, argument: "com.apple.finder")]), "Ordinary application unchanged")
        check(!WindowOverviewAction.matches([WindowOverviewAction.step, .init(kind: .delay)]), "Macro sequence not intercepted")
        let preset = ActionCatalog.presets.first { $0.id == "windows.rotary-overview" }
        check(preset.map { WindowOverviewAction.matches([$0.step]) } == true, "Library exposes rotary overview")
        let document = RadialMenuDocument(schemaVersion: 3, enabled: true, items: [WindowOverviewAction.item], activation: .knobPress)
        check(try RadialMenuCodec.decode(RadialMenuCodec.encode(document)) == document, "Existing schema roundtrip")
        var router = WindowOverviewInputRouter()
        check(!router.handle("knob.right", pressed: true, selectedID: nil, eligible: true).consumed, "Inactive inputs unchanged")
        router.begin(cancelTriggerID: "key.2")
        check(router.handle("knob.press", pressed: false, selectedID: 1, eligible: true).effect == nil, "Opening release cannot confirm")
        check(router.handle("knob.right", pressed: true, selectedID: 1, eligible: true).effect == .rotate(1), "Right input intercepted")
        check(router.handle("knob.right", pressed: false, selectedID: 2, eligible: true).consumed, "Rotation release consumed")
        check(router.handle("knob.press", pressed: true, selectedID: 2, eligible: true).effect == nil, "Confirmation waits for release")
        check(router.handle("knob.press", pressed: true, selectedID: 2, eligible: true).effect == nil, "Repeated press cannot execute")
        check(router.handle("knob.press", pressed: false, selectedID: 2, eligible: true).effect == .confirm(2), "One confirmation for a pair")
        _ = router.handle("knob.press", pressed: true, selectedID: 2, eligible: true)
        check(router.handle("knob.press", pressed: false, selectedID: 3, eligible: true).effect == nil, "Rotation during held confirm cannot choose a new window")
        _ = router.handle("knob.press", pressed: true, selectedID: 2, eligible: true)
        router.end()
        check(router.handle("knob.press", pressed: false, selectedID: nil, eligible: true).consumed, "Cancelled confirmation release never leaks Control")
        router.begin(cancelTriggerID: "key.2")
        check(router.handle("key.2", pressed: true, selectedID: 2, eligible: true).effect == .cancel, "Hardware cancel")
        check(router.handle("key.2", pressed: false, selectedID: nil, eligible: true).consumed, "Cancel release never leaks Backspace")
        router.begin(cancelTriggerID: "key.0")
        check(router.handle("key.0", pressed: true, selectedID: 1, eligible: false).effect == .cancel, "Ineligible session cancels")
        check(router.handle("key.0", pressed: false, selectedID: nil, eligible: true).consumed, "Disconnect release owned")
        print("{\"status\":\"PASS\",\"checks\":\(checks),\"systemInputPosted\":0,\"deviceWrites\":0}")
    }
}
