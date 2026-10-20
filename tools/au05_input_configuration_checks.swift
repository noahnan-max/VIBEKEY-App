import AppKit
import VibekeyCore

@main @MainActor struct InputConfigurationChecks {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { guard value else { fatalError(message) }; checks += 1 }
        func executes(_ effects: [RadialGestureEffect]) -> Bool { effects.contains { if case .execute = $0 { return true }; return false } }
        func forwarded(_ effects: [RadialGestureEffect]) -> Bool { effects.contains { if case .forward = $0 { return true }; return false } }
        let legacy = WorkflowStep(kind: .passthrough)
        let shown = AU05ActionDefaults.displayed(legacy, triggerID: "knob.right")
        check(shown.id == legacy.id && shown.kind == .scrollDown && shown.scrollLines == 3 && legacy.kind == .passthrough, "Legacy display mutated data or lost explicit base action")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shown)) as! [String: Any]
        object.removeValue(forKey: "scrollLines")
        let decoded = try JSONDecoder().decode(WorkflowStep.self, from: JSONSerialization.data(withJSONObject: object))
        check(decoded.scrollLines == 3, "Old step did not get a bounded default")
        for value in [0, 51, Int.max] { check(WorkflowStep(kind: .scrollDown, scrollLines: value).validationError != nil, "Invalid scroll amount accepted") }
        var events: [CGEvent] = []
        let output = AU05OriginalActions(authorized: { true }, physicalModifiers: { [] }, deliver: { events.append($0) })
        output.handle("knob.right", pressed: true)
        check(events.last?.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -3, "Base detent was not three lines")
        events.removeAll()
        for _ in 0..<100 { output.scroll(WorkflowStep(kind: .scrollDown, scrollLines: 17)) }
        check(events.count == 100 && events.allSatisfy { $0.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -17 }, "Continuous custom scrolling was dropped or scaled incorrectly")
        output.handle("key.0", pressed: true); output.scroll(WorkflowStep(kind: .scrollUp, scrollLines: 50))
        check(events.last!.flags.contains(.maskControl) && events.last?.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 50, "Held modifiers or maximum amount lost")
        output.releaseAll(); let count = events.count
        output.scroll(WorkflowStep(kind: .scrollDown, scrollLines: 51)); check(events.count == count, "Invalid scroll posted")
        let denied = AU05OriginalActions(authorized: { false }, physicalModifiers: { [] }, deliver: { _ in fatalError("Unauthorized scroll") })
        denied.scroll(WorkflowStep(kind: .scrollUp))
        let items = (0..<3).map { RadialMenuItem(name: "Test\($0)", steps: [WorkflowStep(kind: .shortcut, keyCode: 8)]) }
        for mode in RadialActivation.allCases {
            let doc = RadialMenuDocument(schemaVersion: 3, enabled: true, items: items, activation: mode)
            check(try RadialMenuCodec.decode(RadialMenuCodec.encode(doc)) == doc, "V3 round trip")
            func open() throws -> RadialGestureRouter {
                var r = RadialGestureRouter(); try r.configure(doc)
                let down = r.handle(id: mode.triggerID, pressed: true, now: 1, eligible: true)
                if mode.requiresHold {
                    guard let token = r.pendingHold else { fatalError("Missing hold") }
                    _ = r.holdFired(token: token, now: 1.5, eligible: true)
                } else { check(!forwarded(down), "Single trigger leaked base key") }
                check(r.isPresented, "Configured trigger did not open")
                check(!executes(r.handle(id: mode.triggerID, pressed: false, now: 1.6, eligible: true)), "Initial release confirmed")
                return r
            }
            var r = try open()
            _ = r.handle(id: "knob.right", pressed: true, now: 1.7, eligible: true)
            check(r.presentation?.selectedIndex == 1, "Scroll gain affected wheel selection")
            _ = r.handle(id: mode.triggerID, pressed: true, now: 2, eligible: true)
            let confirmed = r.handle(id: mode.triggerID, pressed: false, now: 2.1, eligible: true)
            check(executes(confirmed) && !forwarded(confirmed) && !r.isPresented, "Second trigger did not confirm cleanly")
            r = try open(); let cancelled = r.handle(id: mode.cancelTriggerID, pressed: true, now: 2, eligible: true)
            check(!r.isPresented && !executes(cancelled) && !forwarded(cancelled), "Cancel conflicted with trigger")
            check(!forwarded(r.handle(id: mode.cancelTriggerID, pressed: false, now: 2.1, eligible: true)), "Cancel release leaked")
            r = try open(); _ = r.handle(id: mode.triggerID, pressed: true, now: 2, eligible: true)
            let lost = r.handle(id: mode.triggerID, pressed: false, now: 2.1, eligible: false)
            check(!executes(lost) && !forwarded(lost), "Focus loss leaked confirmation")
            if mode.requiresHold {
                var short = RadialGestureRouter(); try short.configure(doc)
                _ = short.handle(id: mode.triggerID, pressed: true, now: 1, eligible: true)
                let tap = short.handle(id: mode.triggerID, pressed: false, now: 1.1, eligible: true)
                check(tap.contains { if case .replayTap(let id, _) = $0 { return id == mode.triggerID }; if case .replayMiddleTap = $0 { return mode.triggerID == "key.1" }; return false }, "Short tap lost")
            }
        }
        let result: [String: Any] = ["status": "PASS", "checks": checks, "activationModes": 8, "continuousDetents": 100, "systemInputPosted": 0, "physicalDeviceWrites": 0]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: .prettyPrinted), as: UTF8.self))
    }
}
