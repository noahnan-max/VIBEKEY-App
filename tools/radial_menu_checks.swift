import Foundation
import VibekeyCore

private struct Failure: Error { let name: String }
private func require(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
    if try !value() { throw Failure(name: name) }
}
private func item(_ index: Int = 0) -> RadialMenuItem {
    RadialMenuItem(name: "选项 \(index)", steps: [WorkflowStep(kind: .shortcut, keyCode: 8, modifiers: 0x00100000)])
}
private func document(_ count: Int = 9, enabled: Bool = true) -> RadialMenuDocument {
    RadialMenuDocument(enabled: enabled, items: (0..<count).map(item))
}
private func executions(_ effects: [RadialGestureEffect]) -> [RadialMenuItem] {
    effects.compactMap { if case .execute(_, let item) = $0 { return item }; return nil }
}
private func replays(_ effects: [RadialGestureEffect]) -> [UInt64] {
    effects.compactMap { if case .replayMiddleTap(let modifiers) = $0 { return modifiers }; return nil }
}
private func arm(_ router: inout RadialGestureRouter, at time: Double = 0, modifiers: UInt64 = 0) throws -> RadialHoldToken {
    let effects = router.handle(id: "key.1", pressed: true, now: time, eligible: true, modifiers: modifiers)
    guard effects.count == 1, case .scheduleHold(let token, let deadline) = effects[0] else { throw Failure(name: "middle down did not arm exactly one hold") }
    try require(abs(deadline - time - 0.45) < 0.000001, "hold deadline")
    return token
}
private func opened(_ count: Int = 9) throws -> RadialGestureRouter {
    var router = RadialGestureRouter(); try router.configure(document(count))
    let token = try arm(&router)
    let effects = router.holdFired(token: token, now: 0.45, eligible: true)
    try require(effects.count == 2 && router.isPresented, "long hold did not open")
    try require(router.handle(id: "key.1", pressed: false, now: 0.46, eligible: true).isEmpty, "initial long release executed")
    return router
}

@main private enum RadialChecks {
    static func main() throws {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--output" else {
            print("Usage: radial-menu-checks --output /absolute/owned/result.json"); exit(2)
        }
        var rows: [[String: Any]] = []
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); rows.append(["case": name, "result": "PASS"]) }
            catch { rows.append(["case": name, "result": "FAIL", "error": String(describing: error)]) }
        }
        func rejects(_ body: () throws -> Void) throws {
            do { try body() } catch { return }
            throw Failure(name: "invalid input accepted")
        }
        run("schema_round_trip_order_and_default_off") {
            let empty = RadialMenuDocument()
            try require(!empty.enabled && empty.items.isEmpty, "default enabled")
            try require(try RadialMenuCodec.decode(RadialMenuCodec.encode(empty)) == empty, "empty round trip")
            let doc = document(64)
            try require(try RadialMenuCodec.decode(RadialMenuCodec.encode(doc)) == doc, "full round trip")
            try require(doc.pageCount == 8 && doc.page(7).count == 8 && doc.page(-1).isEmpty && doc.page(Int.max).isEmpty, "page bounds")
            let reordered = try doc.reordered(ids: doc.items.map(\.id).reversed())
            try require(reordered.items == doc.items.reversed(), "explicit order changed items")
            try rejects { _ = try doc.reordered(ids: Array(repeating: doc.items[0].id, count: 64)) }
            try rejects { _ = try doc.reordered(ids: Array(doc.items.map(\.id).dropLast())) }
        }
        run("configuration_rejects_invalid_identity_size_and_actions") {
            try rejects { try RadialMenuValidation.validate(document(65)) }
            try rejects { try RadialMenuValidation.validate(document(0)) }
            var doc = document(2); doc.items[1].id = doc.items[0].id
            try rejects { try RadialMenuValidation.validate(doc) }
            for name in ["", " \t", "a\nb", "\u{0}", String(repeating: "字", count: 129)] {
                try rejects { try RadialMenuValidation.validate(RadialMenuDocument(items: [RadialMenuItem(name: name, steps: item().steps)])) }
            }
            for step in [WorkflowStep(kind: .passthrough), WorkflowStep(kind: .openApp, argument: "/tmp/unread.app"), WorkflowStep(kind: .openURL, argument: "file:///tmp/private"), WorkflowStep(kind: .shortcut, keyCode: 128), WorkflowStep(kind: .shortcut, modifiers: 1), WorkflowStep(kind: .delay, seconds: .nan)] {
                try rejects { try RadialMenuValidation.validate(RadialMenuDocument(items: [RadialMenuItem(name: "无效", steps: [step])])) }
            }
            let duplicate = WorkflowStep(kind: .delay, seconds: 0)
            try rejects { try RadialMenuValidation.validate(RadialMenuDocument(items: [RadialMenuItem(name: "重复", steps: [duplicate, duplicate])])) }
            try rejects { try RadialMenuValidation.validate(RadialMenuDocument(items: [RadialMenuItem(name: "无步骤", steps: [])])) }
            try rejects { try RadialMenuValidation.validate(RadialMenuDocument(items: [RadialMenuItem(name: "过多步骤", steps: (0..<65).map { _ in WorkflowStep(kind: .delay, seconds: 0) })])) }
            try rejects { try RadialMenuValidation.validate(RadialMenuDocument(items: [RadialMenuItem(name: "超时", steps: (0..<5).map { _ in WorkflowStep(kind: .delay, seconds: 30) })])) }
        }
        run("codec_future_corrupt_and_unknown_action_fail_closed") {
            for text in ["{broken", "[]", "{\"schemaVersion\":2,\"enabled\":false,\"items\":[]}", "{\"schemaVersion\":true,\"enabled\":false,\"items\":[]}"] {
                try rejects { _ = try RadialMenuCodec.decode(Data(text.utf8)) }
            }
            let encoded = try RadialMenuCodec.encode(document(1))
            let unknown = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "\"shortcut\"", with: "\"shell\"")
            try rejects { _ = try RadialMenuCodec.decode(Data(unknown.utf8)) }
            try rejects { _ = try RadialMenuCodec.decode(Data(repeating: 32, count: 1_048_577)) }
            let good = RadialMenuDocument(items: [RadialMenuItem(name: "打开 👩🏽‍💻", steps: [WorkflowStep(kind: .openApp, argument: "com.apple.TextEdit")])])
            try require(try RadialMenuCodec.decode(RadialMenuCodec.encode(good)) == good, "unicode name or bundle ID changed")
        }
        run("presentation_public_preview_and_partial_last_page") {
            let doc = document(9, enabled: false)
            let view = try RadialPresentation(session: RadialHoldToken(session: UUID(), press: 0), items: doc.items, selectedIndex: 8)
            try require(view.globalSelectedIndex == 8 && view.selectedItem == doc.items[8] && view.totalCount == 9, "global selection")
            try require(view.pageIndex == 1 && view.pageCount == 2 && view.slotIndex == 0 && view.items == [doc.items[8]], "page presentation")
            try rejects { _ = try RadialPresentation(session: view.session, items: [], selectedIndex: 0) }
        }
        run("geometry_eight_clockwise_centres_and_boundaries") {
            for count in 1...8 {
                for slot in 0..<8 {
                    let angle = RadialMenuGeometry.centerAngle(slot: slot)!
                    let hit = RadialMenuGeometry.hitTest(x: cos(angle) * 100, y: sin(angle) * 100, innerRadius: 50, outerRadius: 150, itemCount: count)
                    try require(hit == (slot < count ? slot : nil), "sector centre or empty slot")
                    if count == 8 {
                        for side in [-1.0, 1.0] {
                            let boundary = angle + .pi / 8 + side * 0.000001
                            let index = RadialMenuGeometry.hitTest(x: cos(boundary) * 100, y: sin(boundary) * 100, innerRadius: 50, outerRadius: 150, itemCount: 8)
                            try require(index == (side < 0 ? slot : (slot + 1) % 8), "clockwise sector boundary")
                        }
                    }
                }
            }
            try require(RadialMenuGeometry.hitTest(x: 0, y: 0, innerRadius: 0, outerRadius: 100, itemCount: 8) == nil, "centre hit")
            try require(RadialMenuGeometry.hitTest(x: 50, y: 0, innerRadius: 50, outerRadius: 100, itemCount: 8) == nil, "inner boundary hit")
            try require(RadialMenuGeometry.hitTest(x: 100.1, y: 0, innerRadius: 50, outerRadius: 100, itemCount: 8) == nil, "outside hit")
            try require(RadialMenuGeometry.hitTest(x: 100, y: 0, innerRadius: 50, outerRadius: 100, itemCount: 8) == 2, "outer boundary omitted")
            for invalid in [Double.nan, Double.infinity, -Double.infinity] {
                try require(RadialMenuGeometry.hitTest(x: invalid, y: 0, innerRadius: 0, outerRadius: 100, itemCount: 8) == nil, "nonfinite point")
            }
            try require(RadialMenuGeometry.hitTest(x: 70, y: 0, innerRadius: 100, outerRadius: 50, itemCount: 8) == nil, "inverted annulus")
            for count in [0,9] { try require(RadialMenuGeometry.hitTest(x: 100, y: 0, innerRadius: 50, outerRadius: 150, itemCount: count) == nil, "invalid sector count") }
        }
        run("default_off_and_ineligible_preserve_original_middle_pair") {
            for enabled in [false, true] {
                var router = RadialGestureRouter(); try router.configure(document(1, enabled: enabled))
                let down = router.handle(id: "key.1", pressed: true, now: 0, eligible: !enabled)
                let up = router.handle(id: "key.1", pressed: false, now: 0.1, eligible: true)
                try require(down == [.forward(id: "key.1", pressed: true)] && up == [.forward(id: "key.1", pressed: false)], "original pair changed")
            }
        }
        run("short_tap_delays_one_return_and_freezes_modifiers") {
            var router = RadialGestureRouter(); try router.configure(document())
            let token = try arm(&router, modifiers: 0x00020000)
            for _ in 0..<10 { try require(router.handle(id: "key.1", pressed: true, now: 0.1, eligible: true).isEmpty, "duplicate down escaped") }
            let up = router.handle(id: "key.1", pressed: false, now: 0.2, eligible: true, modifiers: 0x00100000)
            try require(up == [.cancelHold(token: token), .replayMiddleTap(modifiers: 0x00020000)], "short tap did not replay one frozen pair")
            try require(router.handle(id: "key.1", pressed: false, now: 0.3, eligible: true).isEmpty, "orphan up replayed")
            try require(router.holdFired(token: token, now: 1, eligible: true).isEmpty, "late timer opened")
        }
        run("long_hold_timer_is_one_shot_and_initial_up_never_confirms") {
            var router = RadialGestureRouter(); try router.configure(document())
            let token = try arm(&router)
            try require(router.holdFired(token: token, now: 0.2, eligible: true) == [.scheduleHold(token: token, deadline: 0.45)], "early timer opened or lost reschedule")
            let show = router.holdFired(token: token, now: 0.45, eligible: true)
            try require(show.count == 2 && router.isPresented && executions(show).isEmpty, "long open")
            try require(router.holdFired(token: token, now: 0.46, eligible: true).isEmpty, "duplicate hold")
            try require(router.handle(id: "key.1", pressed: true, now: 0.47, eligible: true).isEmpty, "opening duplicate down")
            try require(router.handle(id: "key.1", pressed: false, now: 0.48, eligible: true).isEmpty && router.isPresented, "opening release confirmed")
        }
        run("late_up_without_timer_opens_without_return_or_execution") {
            var router = RadialGestureRouter(); try router.configure(document())
            let token = try arm(&router)
            let effects = router.handle(id: "key.1", pressed: false, now: 0.8, eligible: true)
            try require(router.isPresented && replays(effects).isEmpty && executions(effects).isEmpty, "late up made Return or executed")
            try require(router.holdFired(token: token, now: 0.9, eligible: true).isEmpty, "late timer reopened")
        }
        for key in ["key.1", "knob.press"] {
            run("confirmation_short_release_" + key) {
                var router = try opened(); let chosen = router.presentation!.selectedItem
                try require(router.handle(id: key, pressed: true, now: 1, eligible: true).isEmpty, "confirm down leaked")
                try require(router.handle(id: key, pressed: true, now: 1.05, eligible: true).isEmpty, "repeat confirm down leaked")
                let effects = router.handle(id: key, pressed: false, now: 1.1, eligible: true)
                try require(executions(effects) == [chosen] && effects.count == 2 && !router.isPresented, "confirm did not dismiss/execute exactly once")
                guard case .dismiss(_, .confirmed) = effects[0], case .execute = effects[1] else { throw Failure(name: "execute occurred before dismissal") }
                try require(executions(router.handle(id: key, pressed: false, now: 1.2, eligible: true)).isEmpty, "duplicate up executed")
            }
        }
        run("long_or_changed_selection_confirmation_does_not_execute") {
            var router = try opened()
            _ = router.handle(id: "key.1", pressed: true, now: 1, eligible: true)
            try require(executions(router.handle(id: "key.1", pressed: false, now: 1.6, eligible: true)).isEmpty && router.isPresented, "long confirmation executed")
            _ = router.handle(id: "key.1", pressed: true, now: 2, eligible: true)
            _ = router.handle(id: "knob.right", pressed: true, now: 2.05, eligible: true)
            try require(executions(router.handle(id: "key.1", pressed: false, now: 2.1, eligible: true)).isEmpty && router.isPresented, "changed item executed")
        }
        run("wheel_crosses_pages_wraps_and_never_forwards_while_open") {
            var router = try opened(64)
            for index in 1...8 {
                let effects = router.handle(id: "knob.right", pressed: true, now: 1 + Double(index) / 10, eligible: true)
                try require(router.presentation?.selectedIndex == index && effects.count == 1, "wheel did not move one")
            }
            try require(router.presentation?.pageIndex == 1 && router.presentation?.slotIndex == 0, "page crossing")
            _ = router.select(index: 0, eligible: true)
            _ = router.handle(id: "knob.left", pressed: true, now: 3, eligible: true)
            try require(router.presentation?.selectedIndex == 63 && router.presentation?.pageIndex == 7, "left wrap")
            try require(router.handle(id: "knob.right", pressed: false, now: 3.1, eligible: true).isEmpty, "wheel false leaked while open")
            var single = try opened(1)
            try require(single.handle(id: "knob.right", pressed: true, now: 1, eligible: true).isEmpty, "single item rotated or leaked")
        }
        run("lower_cancel_consumes_entire_press_then_restores_forwarding") {
            var router = try opened()
            let down = router.handle(id: "key.2", pressed: true, now: 1, eligible: true)
            try require(down.count == 1 && !router.isPresented, "cancel down did not just dismiss")
            try require(router.handle(id: "key.2", pressed: true, now: 1.1, eligible: true).isEmpty, "cancel duplicate leaked")
            try require(router.handle(id: "key.2", pressed: false, now: 1.2, eligible: true).isEmpty, "cancel up leaked")
            try require(router.handle(id: "key.2", pressed: true, now: 2, eligible: true) == [.forward(id: "key.2", pressed: true)], "closed Backspace lost")
        }
        run("upper_key_dismisses_first_and_preserves_control_down_up") {
            var router = try opened()
            let effects=router.handle(id:"key.0",pressed:true,now:1,eligible:true)
            guard effects.count==2,case .dismiss(_, .upperKey)=effects[0],case .forward("key.0",true)=effects[1] else {throw Failure(name:"upper key ordering")}
            try require(router.handle(id:"key.0",pressed:false,now:1.1,eligible:true)==[.forward(id:"key.0",pressed:false)],"Control up missing")
        }

        run("forwarded_modifier_up_remains_forwarded_after_menu_opens") {
            var router = RadialGestureRouter(); try router.configure(document())
            try require(router.handle(id: "knob.press", pressed: true, now: 0, eligible: true) == [.forward(id: "knob.press", pressed: true)], "closed knob modifier lost")
            let token = try arm(&router, at: 0.1)
            _ = router.holdFired(token: token, now: 0.6, eligible: true)
            try require(router.handle(id: "knob.press", pressed: false, now: 0.7, eligible: true) == [.forward(id: "knob.press", pressed: false)], "held modifier up consumed by menu")
            try require(router.isPresented, "modifier up confirmed menu")
        }
        for reason in [RadialDismissReason.disconnected,.ownershipChanged,.windowClosed,.permissionChanged,.targetChanged,.disabled,.reset] {
            run("pending_reset_" + reason.rawValue) {
                var router = RadialGestureRouter(); try router.configure(document())
                let token = try arm(&router)
                try require(router.reset(reason: reason) == [.cancelHold(token: token)], "pending reset emitted action")
                try require(router.handle(id: "key.1", pressed: true, now: 1, eligible: true).isEmpty, "reset forgot consumed down")
                try require(router.handle(id: "key.1", pressed: false, now: 1.1, eligible: true).isEmpty, "reset up replayed")
                let fresh = try arm(&router, at: 2)
                try require(fresh != token && router.holdFired(token: token, now: .nan, eligible: true).isEmpty && router.pendingHold == fresh, "stale timer disturbed fresh session")
            }
            run("open_confirm_reset_" + reason.rawValue) {
                var router = try opened()
                _ = router.handle(id: "key.1", pressed: true, now: 1, eligible: true)
                let effects = router.reset(reason: reason)
                try require(effects.count == 1 && executions(effects).isEmpty, "reset executed selection")
                try require(router.handle(id: "key.1", pressed: false, now: 1.1, eligible: true).isEmpty, "late confirm after reset")
            }
        }
        run("eligibility_and_clock_changes_discard_pending_tap") {
            for time in [Double.nan, -1, 0.5] {
                var router = RadialGestureRouter(); try router.configure(document())
                _ = try arm(&router, at: 1)
                let up = router.handle(id: "key.1", pressed: false, now: time, eligible: true)
                try require(replays(up).isEmpty && executions(up).isEmpty && !router.isPresented, "invalid time replayed")
            }
            var router = RadialGestureRouter(); try router.configure(document())
            let token = try arm(&router)
            try require(router.holdFired(token: token, now: 0.5, eligible: false) == [.cancelHold(token: token)], "ineligible hold not cancelled")
            try require(router.handle(id: "key.1", pressed: false, now: 0.6, eligible: true).isEmpty, "eligibility reset lost release debt")
        }
        run("configuration_change_preserves_consumed_release_and_invalid_keeps_last_good") {
            var router = RadialGestureRouter(); let doc = document(); try router.configure(doc)
            let token = try arm(&router)
            try rejects { _ = try router.configure(document(65)) }
            try require(router.configuration == doc && router.pendingHold == token, "invalid config destroyed last good")
            var disabled = doc; disabled.enabled = false
            try require(try router.configure(disabled) == [.cancelHold(token: token)], "disable did not cancel timer")
            try require(router.handle(id: "key.1", pressed: false, now: 1, eligible: true).isEmpty, "disabled late up leaked")
        }
        run("two_confirmation_buttons_cannot_double_execute") {
            var router = try opened()
            _ = router.handle(id: "key.1", pressed: true, now: 1, eligible: true)
            _ = router.handle(id: "knob.press", pressed: true, now: 1.05, eligible: true)
            let first = router.handle(id: "key.1", pressed: false, now: 1.1, eligible: true)
            let second = router.handle(id: "knob.press", pressed: false, now: 1.15, eligible: true)
            try require(executions(first).count == 1 && second.isEmpty, "concurrent confirmations escaped debt ownership")
        }
        run("eligibility_loss_on_new_menu_control_does_not_leak_to_new_target") {
            for key in ["key.1", "key.2", "knob.press", "knob.left", "knob.right"] {
                var router = try opened()
                let effects = router.handle(id: key, pressed: true, now: 1, eligible: false)
                guard effects.count == 1, case .dismiss(_, .ineligible) = effects[0] else { throw Failure(name: "invalidated menu control became an ordinary action") }
                if key != "knob.left" && key != "knob.right" {
                    try require(router.handle(id: key, pressed: false, now: 1.1, eligible: true).isEmpty, "invalidated control up leaked")
                }
                try require(!router.isPresented, "ineligible menu stayed open")
            }
        }
        run("closed_other_keys_and_rotations_are_unchanged") {
            var router = RadialGestureRouter(); try router.configure(document())
            var time = 0.0
            for key in ["key.0", "key.2", "knob.press", "knob.left", "knob.right", "unknown"] {
                for pressed in [true, false] {
                    time += 0.1
                    try require(router.handle(id: key, pressed: pressed, now: time, eligible: true) == [.forward(id: key, pressed: pressed)], "ordinary event changed")
                }
            }
        }
        let passed = rows.allSatisfy { $0["result"] as? String == "PASS" }
        let receipt: [String: Any] = ["result": passed ? "PASS" : "FAIL", "caseCount": rows.count, "cases": rows,
            "workflowActionsExecuted": 0, "systemEventsPosted": 0, "hardwareAccess": false, "GUI": false,
            "configurationIO": "Data codec only; no real Store read/write", "physicalHIDOrStudioLeakage": "NOT_RUN",
            "scope": "Pure configuration/geometry/event-sequence contracts; root owns UI, delivery and hardware validation"]
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted,.sortedKeys]).write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        print("\(passed ? "PASS" : "FAIL") \(rows.count) radial pure cases; 0 actions executed")
        if !passed { for row in rows where row["result"] as? String == "FAIL" { print(row) }; exit(1) }
    }
}
