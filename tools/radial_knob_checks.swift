import Foundation
import VibekeyCore

@main enum KnobWheelChecks {
    static func main() throws {
        var checks=0
        func check(_ value:Bool,_ name:String) {guard value else {fatalError(name)};checks += 1}
        let items=(0..<9).map {RadialMenuItem(name:"Action \($0)",steps:[.init(kind:.delay,seconds:0)])}
        let configuration=RadialMenuDocument(schemaVersion:2,enabled:true,items:items,activation:.knobPress)
        func hasForward(_ values:[RadialGestureEffect])->Bool {values.contains{if case .forward=$0 {return true};return false}}
        func executions(_ values:[RadialGestureEffect])->Int {values.filter{if case .execute=$0 {return true};return false}.count}
        func opens(_ values:[RadialGestureEffect])->Int {values.filter{if case .show=$0 {return true};return false}.count}
        var router=RadialGestureRouter();try router.configure(configuration)
        let first=router.handle(id:"knob.press",pressed:true,now:1,eligible:true)
        check(opens(first)==1 && executions(first)==0 && !hasForward(first) && router.pendingHold==nil,"First knob press must only open")
        check(router.handle(id:"knob.press",pressed:true,now:1.01,eligible:true).isEmpty,"Duplicate opening down")
        check(router.handle(id:"knob.press",pressed:false,now:1.1,eligible:true).isEmpty && router.isPresented,"Opening release confirmed or leaked")
        let turn=router.handle(id:"knob.right",pressed:true,now:1.2,eligible:true)
        check(router.presentation?.selectedIndex==1 && !hasForward(turn),"Wheel rotation did not select")
        _ = router.handle(id:"knob.press",pressed:true,now:1.3,eligible:true)
        _ = router.handle(id:"knob.press",pressed:true,now:1.4,eligible:true)
        let confirmation=router.handle(id:"knob.press",pressed:false,now:2.3,eligible:true)
        check(executions(confirmation)==1 && !hasForward(confirmation) && !router.isPresented,"Held confirmation must execute exactly once")
        check(router.handle(id:"knob.press",pressed:false,now:2.4,eligible:true).isEmpty,"Orphan trigger up leaked")
        check(hasForward(router.handle(id:"key.1",pressed:true,now:3,eligible:true)),"Middle Return blocked outside wheel")
        check(hasForward(router.handle(id:"key.1",pressed:false,now:3.1,eligible:true)),"Middle Return up lost")
        check(hasForward(router.handle(id:"knob.left",pressed:true,now:3.2,eligible:true)),"Normal scrolling blocked outside wheel")
        check(router.handle(id:"knob.press",pressed:true,now:4,eligible:false).isEmpty,"Ineligible trigger leaked Right Control")
        check(router.handle(id:"knob.press",pressed:false,now:4.1,eligible:true).isEmpty,"Ineligible trigger up leaked")
        _ = router.handle(id:"knob.press",pressed:true,now:5,eligible:true);_ = router.handle(id:"knob.press",pressed:false,now:5.1,eligible:true)
        _ = router.handle(id:"knob.left",pressed:true,now:5.2,eligible:true)
        check(router.presentation?.selectedIndex==8 && router.presentation?.pageIndex==1,"Wrap to next page")
        let cancelled=router.handle(id:"key.2",pressed:true,now:5.3,eligible:true)
        check(!router.isPresented && executions(cancelled)==0 && !hasForward(cancelled),"Cancel leaked Backspace")
        check(router.handle(id:"key.2",pressed:false,now:5.4,eligible:true).isEmpty,"Cancel up leaked")
        _ = router.handle(id:"knob.press",pressed:true,now:6,eligible:true);_ = router.reset(reason:.disconnected)
        check(router.handle(id:"knob.press",pressed:false,now:6.1,eligible:true).isEmpty,"Disconnect release leaked")
        _ = router.handle(id:"knob.press",pressed:true,now:7,eligible:true);_ = router.handle(id:"knob.press",pressed:false,now:7.1,eligible:true)
        _ = router.handle(id:"knob.press",pressed:true,now:7.2,eligible:true)
        let invalid=router.handle(id:"knob.press",pressed:false,now:7.3,eligible:false)
        check(executions(invalid)==0 && !hasForward(invalid) && !router.isPresented,"Focus-loss confirmation executed")
        var off=configuration;off.enabled=false;try router.configure(off)
        check(hasForward(router.handle(id:"knob.press",pressed:true,now:8,eligible:true)),"Disabled wheel lost Right Control")
        check(hasForward(router.handle(id:"knob.press",pressed:false,now:8.1,eligible:true)),"Disabled wheel lost Right Control up")
        let legacy=Data("{\"schemaVersion\":1,\"enabled\":false,\"items\":[]}".utf8)
        check(try RadialMenuCodec.decode(legacy).activation == .middleHold,"Legacy activation migrated silently")
        check(try RadialMenuCodec.decode(RadialMenuCodec.encode(configuration)) == configuration,"V2 round trip changed items")
        var rejected=false;do {_ = try RadialMenuCodec.decode(Data("{\"schemaVersion\":3,\"enabled\":false,\"items\":[]}".utf8))} catch {rejected=true}
        check(rejected,"Future schema accepted")
        print("{\"status\":\"PASS\",\"checks\":\(checks),\"systemInputPosted\":0,\"physicalDeviceWrites\":0}")
    }
}
