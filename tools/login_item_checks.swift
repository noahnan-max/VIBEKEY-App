import AppKit
import ServiceManagement
import Carbon

@MainActor final class LoginFixture: LoginItemManaging {
    var status: SMAppService.Status = .notRegistered
    var denied = false
    func setEnabled(_ enabled: Bool) throws {
        if denied { throw NSError(domain: "LoginFixture", code: 1) }
        status = enabled ? .enabled : .notRegistered
    }
}

@main @MainActor enum LoginChecks {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ name: String) {
            guard value else { fatalError(name) }; count += 1
        }
        let service = LoginFixture(), store = LoginItemStore(live: false, service: LoginFixture())
        check(!store.enabled, "No optimistic login enablement")
        let active = LoginItemStore(live: false, service: service)
        active.setEnabled(true); check(active.enabled && !active.needsApproval, "Register readback")
        active.setEnabled(false); check(!active.enabled, "Unregister readback")
        service.denied = true; active.setEnabled(true)
        check(!active.enabled && active.errorMessage != nil, "Failed registration cannot claim enabled")
        service.status = .requiresApproval; active.refresh()
        check(active.enabled && active.needsApproval, "Approval is visible and not claimed eligible")
        service.status = .notRegistered; active.refresh(); check(!active.enabled, "External revocation refreshes")
        let state = AppLaunchState(arguments: ["app", "--background"])
        check(state.background, "Explicit background launch")
        state.revealMainWindow(); check(!state.background, "Explicit reopen may show main window")
        let manual = AppLaunchState(arguments: ["app"])
        check(!manual.background && !AppLaunchState.isLoginEvent(nil), "Manual launch unaffected")
        for kind in [keyAELaunchedAsLogInItem, keyAELaunchedAsServiceItem] {
            let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(NSAppleEventDescriptor(enumCode: kind), forKeyword: keyAEPropData)
            manual.readLoginEvent(event)
            check(manual.background && manual.launchedAtLogin, "Both native login event forms hide main window")
        }
        print("PASS: \(count) login/launch checks; no real login registrations or system settings changed")
    }
}
