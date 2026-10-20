import AppKit
import VibekeyCore

@main @MainActor enum WindowOverviewControllerChecks {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
        let a = WindowOverviewTarget(id: 11, frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let b = WindowOverviewTarget(id: 22, frame: CGRect(x: 250, y: 0, width: 200, height: 100))
        var values = [a, b], visible = false, permitted = true
        var opens = 0, cancellations = 0, highlights: [UInt32] = [], confirmations: [UInt32] = []
        func make(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> WindowOverviewController {
            .init(adapter: .init(permitted: { permitted }, open: { opens += 1; visible = true },
                snapshot: { .init(visible: visible, targets: visible ? values : []) },
                highlight: { highlights.append($0.id) }, confirm: { confirmations.append($0); visible = false },
                cancel: { cancellations += 1; visible = false }), showsPanel: false, clock: clock,
                sleep: { try await Task.sleep(nanoseconds: 1_000_000) })
        }
        func ready(_ controller: WindowOverviewController) async throws {
            for _ in 0..<100 {
                if controller.selectedID != nil { return }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            throw Failure.failed
        }
        let first = make()
        check(opens == 0 && highlights.isEmpty, "Construction has no UI side effects")
        let run = Task { try await first.run(cancelTriggerID: "key.2") }
        try await ready(first)
        check(first.windowCount == 2 && highlights == [11], "Reads and highlights first current target")
        check(first.handleHardware("knob.right", pressed: true, eligible: true), "Real hardware entry consumed")
        _ = first.handleHardware("knob.right", pressed: false, eligible: true)
        check(first.selectedID == 22 && first.ordinal == 2 && highlights.last == 22, "Rotation selects second target")
        _ = first.handleHardware("knob.press", pressed: true, eligible: true)
        check(confirmations.isEmpty, "Press has no premature activation")
        _ = first.handleHardware("knob.press", pressed: false, eligible: true)
        try await run.value
        check(confirmations == [22] && first.confirmed && !first.isActive, "Release confirms chosen identity once")
        check(first.selectedID == nil && first.windowCount == 0, "Completed session releases window data")
        let stale = make(); values = [a, b]
        let staleRun = Task { try await stale.run(cancelTriggerID: "key.2") }
        try await ready(stale)
        _ = stale.handleHardware("knob.press", pressed: true, eligible: true)
        values = [b]
        _ = stale.handleHardware("knob.press", pressed: false, eligible: true)
        do { try await staleRun.value; preconditionFailure("Closed target was accepted") } catch {}
        check(confirmations == [22] && !stale.confirmed && !stale.isActive, "Closed target cannot activate its replacement")
        let cancelled = make(); values = [a, b]
        let cancelledRun = Task { try await cancelled.run(cancelTriggerID: "key.2") }
        try await ready(cancelled)
        _ = cancelled.handleHardware("knob.press", pressed: true, eligible: true)
        _ = cancelled.handleHardware("key.2", pressed: true, eligible: true)
        try await cancelledRun.value
        check(cancellations == 1 && !cancelled.confirmed, "Cancel closes owned system overview")
        check(cancelled.handleHardware("knob.press", pressed: false, eligible: true), "Cancelled Control release consumed")
        check(cancelled.handleHardware("key.2", pressed: false, eligible: true), "Cancelled Backspace release consumed")
        check(!cancelled.handleHardware("knob.right", pressed: true, eligible: true), "Normal routing resumes after cancellation")
        let disconnected = make()
        let disconnectedRun = Task { try await disconnected.run(cancelTriggerID: "key.2") }
        try await ready(disconnected)
        _ = disconnected.handleHardware("knob.right", pressed: true, eligible: false)
        try await disconnectedRun.value
        check(!disconnected.isActive && cancellations == 2, "Lost device eligibility closes overview")
        let external = make()
        let externalRun = Task { try await external.run(cancelTriggerID: "key.2") }
        try await ready(external); visible = false; try await externalRun.value
        check(!external.isActive && cancellations == 2, "System dismissal needs no synthetic Escape")
        permitted = false; let denied = make(); let priorOpens = opens
        do { try await denied.run(cancelTriggerID: "key.2"); preconditionFailure("Permission check bypassed") } catch {}
        check(opens == priorOpens && !denied.isActive, "Missing permission performs no open or input")
        permitted = true
        var now: TimeInterval = 0
        let timed = make(clock: { now })
        let timedRun = Task { try await timed.run(cancelTriggerID: "key.2") }
        try await ready(timed); now = 61; try await timedRun.value
        check(!timed.isActive && cancellations == 3, "Timeout closes and clears interaction")
        let revoked = make()
        let revokedRun = Task { try await revoked.run(cancelTriggerID: "key.2") }
        try await ready(revoked); permitted = false
        do { try await revokedRun.value; preconditionFailure("Revoked permission was ignored") } catch {}
        check(!revoked.isActive && revoked.selectedID == nil, "Permission revocation clears all targets")
        var loadingVisible = false
        let loading = WindowOverviewController(adapter: .init(permitted: { true }, open: {
            try await Task.sleep(nanoseconds: 50_000_000); loadingVisible = true
        }, snapshot: { .init(visible: loadingVisible, targets: loadingVisible ? [a, b] : []) },
        highlight: { _ in }, confirm: { _ in loadingVisible = false }, cancel: { loadingVisible = false }), showsPanel: false,
        sleep: { try await Task.sleep(nanoseconds: 1_000_000) })
        let loadingRun = Task { try await loading.run(cancelTriggerID: "key.2") }
        for _ in 0..<30 {
            if loading.isActive { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let openingRotation = loading.handleHardware("knob.right", pressed: true, eligible: true)
        _ = loading.handleHardware("knob.right", pressed: false, eligible: true)
        check(openingRotation && loading.isActive, "Rotation during opening is consumed without cancelling the overview")
        try await ready(loading)
        check(loading.selectedID == a.id, "Opening completes after an early rotary input")
        loading.cancel(); try await loadingRun.value
        print("{\"status\":\"PASS\",\"checks\":\(checks),\"adapterOnly\":true,\"physicalDeviceWrites\":0,\"systemInputPosted\":0,\"windowsShown\":0}")
    }
}
private enum Failure: Error { case failed }
