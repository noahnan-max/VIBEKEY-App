import AppKit
import VibekeyCore

@main @MainActor struct OriginalDeliveryChecks {
    static func main() throws {
        var events:[CGEvent] = [];var checks = 0;var failures = 0
        func require(_ condition:Bool,_ description:String) {
            guard condition else {fputs("FAIL: \(description)\n",stderr);exit(1)};checks += 1
        }
        let bridge = AU05OriginalActions(authorized:{true},physicalModifiers:{[]},deliver:{events.append($0)})
        bridge.handle("key.1",pressed:true)
        bridge.handle("key.1",pressed:true)
        bridge.handle("key.1",pressed:false)
        require(events.count == 2,"duplicate Return down")
        require(events[0].type == .keyDown && events[1].type == .keyUp,"Return phase")
        require(events.allSatisfy{$0.getIntegerValueField(.keyboardEventKeycode) == 36},"Return code")
        events.removeAll()
        bridge.handle("key.2",pressed:true)
        bridge.handle("key.2",pressed:false)
        require(events.count == 2 && events[0].getIntegerValueField(.keyboardEventKeycode) == 51,"idle Backspace")
        events.removeAll()
        bridge.handle("key.2",pressed:true)
        bridge.handle("key.2",pressed:false)
        require(events.count == 2,"Backspace remains available");events.removeAll()
        bridge.handle("key.0",pressed:true)
        bridge.handle("key.0",pressed:false)
        require(events.count == 2 && events[0].type == .flagsChanged && events[0].getIntegerValueField(.keyboardEventKeycode) == 59,"upper sends left Control");events.removeAll()
        bridge.handle("knob.press",pressed:true)
        require(events.count == 1 && events[0].type == .flagsChanged,"right Control type")
        require(events[0].getIntegerValueField(.keyboardEventKeycode) == 62 && events[0].flags.rawValue & 0x42000 == 0x42000,"right Control flags")
        bridge.handle("knob.left",pressed:true)
        require(events.last?.type == .scrollWheel && events.last?.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 3,"left scroll up")
        require(events.last!.flags.contains(.maskControl),"held Control applied to scroll")
        bridge.handle("knob.right",pressed:true)
        require(events.last?.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -3,"right scroll down")
        bridge.releaseAll()
        require(events.last?.type == .flagsChanged && !events.last!.flags.contains(.maskControl),"cleanup releases own Control")
        let count = events.count;bridge.releaseAll();require(events.count == count,"cleanup idempotence")
        let shifted = AU05OriginalActions(authorized:{true},physicalModifiers:{.maskShift},deliver:{events.append($0)})
        shifted.handle("key.1",pressed:true)
        require(events.last!.flags.contains(.maskShift),"preserve physical keyboard modifier")
        shifted.releaseAll()
        let denied = AU05OriginalActions(authorized:{false},physicalModifiers:{[]},deliver:{_ in failures += 1})
        denied.handle("key.1",pressed:true);denied.releaseAll()
        require(failures == 0,"no unapproved event delivery")
        var permitted = true;var revoked:[CGEvent] = []
        let revocation = AU05OriginalActions(authorized:{permitted},physicalModifiers:{[]},deliver:{revoked.append($0)})
        revocation.handle("knob.press",pressed:true)
        permitted = false
        revocation.handle("key.1",pressed:true)
        require(revoked.count == 2 && revoked.allSatisfy{$0.getIntegerValueField(.keyboardEventKeycode) == 62},"permission loss only releases previously delivered keys")
        require(!revoked[1].flags.contains(.maskControl),"permission loss leaves no owned modifier")
        print("PASS: \(checks) production event-factory checks; real event objects captured in memory, zero events posted")
    }
}
