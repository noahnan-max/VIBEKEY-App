import Foundation
import VibekeyCore

@main enum RadialScrollChecks {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, name); checks += 1
        }
        var input = RadialScrollInput()
        check(input.consume(deltaY: -1, precise: false) == 1, "Wheel down selects next")
        check(input.consume(deltaY: 1, precise: false) == -1, "Wheel up selects previous")
        check(input.consume(deltaY: 5, precise: true) == 0, "Trackpad noise moved selection")
        check(input.consume(deltaY: 8, precise: true) == -1, "Trackpad did not accumulate")
        check(input.consume(deltaY: 11, precise: true) == -1, "Trackpad remainder was lost")
        check(input.consume(deltaY: 11, precise: true) == 0, "Partial gesture moved selection")
        check(input.consume(deltaY: -12, precise: true) == 1, "Reversal was delayed by old direction")
        check(input.consume(deltaY: 11, precise: true) == 0, "New partial gesture moved selection")
        check(input.consume(deltaY: 1, precise: false) == -1, "Changing input units kept old residue")
        check(input.consume(deltaY: 0.25, precise: false) == 0, "Fractional wheel tick moved too early")
        check(input.consume(deltaY: 0.75, precise: false) == -1, "Fractional wheel ticks did not accumulate")
        input.reset()
        _ = input.consume(deltaY: 11, precise: true)
        input.reset()
        check(input.consume(deltaY: 1, precise: true) == 0, "Closed menu retained old gesture")
        for invalid in [Double.nan, Double.infinity, -Double.infinity, 0] {
            check(input.consume(deltaY: invalid, precise: true) == 0, "Invalid delta moved selection")
        }
        check(input.consume(deltaY: 11, precise: true) == -1, "Invalid delta poisoned accumulation")
        check(input.consume(deltaY: -Double.greatestFiniteMagnitude, precise: true) == 1, "Accelerated event skipped sectors or overflowed")
        check(input.consume(deltaY: 1, precise: false) == -1, "Accelerated event poisoned next input")

        // Exercise the actual shared Controller/Router presentation boundary:
        // 17 entries include two full pages and a one-item final page.
        let items = (0..<17).map { RadialMenuItem(name: "Action \($0)", steps: [.init(kind: .delay, seconds: 0)]) }
        var router = RadialGestureRouter()
        try router.configure(RadialMenuDocument(schemaVersion: 2, enabled: true, items: items, activation: .knobPress))
        _ = router.handle(id: "knob.press", pressed: true, now: 0, eligible: true)
        _ = router.handle(id: "knob.press", pressed: false, now: 0.1, eligible: true)
        var now: TimeInterval = 1
        func turn(_ deltaY: Double) {
            let delta = input.consume(deltaY: deltaY, precise: false)
            let old = router.presentation!
            let next = (old.selectedIndex + delta + old.totalCount) % old.totalCount
            let effects = router.select(index: next, eligible: true)
            check(effects.allSatisfy { if case .move = $0 { return true }; return false }, "Scrolling executed or forwarded an action")
            now += 0.1
        }
        input.reset()
        for _ in 0..<8 { turn(-1) }
        check(router.presentation?.selectedIndex == 8 && router.presentation?.pageIndex == 1, "Full circle did not advance page")
        turn(1)
        check(router.presentation?.selectedIndex == 7 && router.presentation?.pageIndex == 0, "Reversal did not return to prior page")
        _ = router.select(index: 15, eligible: true); turn(-1)
        check(router.presentation?.selectedIndex == 16 && router.presentation?.pageItems.count == 1, "Partial final page was skipped")
        turn(-1)
        check(router.presentation?.selectedIndex == 0, "Last page did not wrap")
        turn(1)
        check(router.presentation?.selectedIndex == 16, "Reverse wrap selected an empty slot")
        print("{\"status\":\"PASS\",\"checks\":\(checks),\"systemInputPosted\":0,\"physicalDeviceWrites\":0}")
    }
}
