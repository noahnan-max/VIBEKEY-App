import Foundation
import VibekeyCore

@main struct HardwareCoreChecks {
    @MainActor static func main() throws {
        var rows:[[String:Any]]=[]
        func check(_ name:String,_ passed:Bool) {rows.append(["name":name,"passed":passed])}
        func rejects(_ body:()throws->Void)->Bool {do {try body();return false} catch {return true}}
        let bindings=InitialDeviceConfiguration.defaults
        check("six original controls",bindings.count==6 && Set(bindings.map(\.triggerID)).count==6)
        check("complete saved daily preset",bindings.allSatisfy{$0.steps.count==1 && $0.validationError == nil}
            && bindings[0].steps[0].kind == .shortcut && bindings[0].steps[0].keyCode == 59
            && bindings[1].steps[0].kind == .passthrough && bindings[1].steps[0].keyCode == 36
            && bindings[2].steps[0].kind == .passthrough && bindings[2].steps[0].keyCode == 51
            && bindings[3].steps[0].kind == .passthrough && bindings[3].steps[0].keyCode == 62
            && bindings[4].steps[0].kind == .scrollUp && bindings[4].steps[0].scrollLines == 19
            && bindings[5].steps[0].kind == .scrollDown && bindings[5].steps[0].scrollLines == 18)
        var originals=OriginalDeviceActionRouter()
        check("upper is left Control",originals.handle("key.0",pressed:true)==[.key(keyCode:59,pressed:true,modifiers:0x40001)])
        check("duplicate upper down ignored",originals.handle("key.0",pressed:true).isEmpty)
        check("upper up releases Control",originals.handle("key.0",pressed:false)==[.key(keyCode:59,pressed:false,modifiers:0)])
        check("middle Return",originals.handle("key.1",pressed:true)==[.key(keyCode:36,pressed:true,modifiers:0)])
        check("middle Return release",originals.handle("key.1",pressed:false)==[.key(keyCode:36,pressed:false,modifiers:0)])
        check("lower Backspace",originals.handle("key.2",pressed:true)==[.key(keyCode:51,pressed:true,modifiers:0)])
        _=originals.handle("key.2",pressed:false)
        check("knob press right Control",originals.handle("knob.press",pressed:true)==[.key(keyCode:62,pressed:true,modifiers:0x42000)])
        check("left scroll retains held modifier",originals.handle("knob.left",pressed:true)==[.scroll(lines:1,modifiers:0x42000)])
        check("right scroll retains held modifier",originals.handle("knob.right",pressed:true)==[.scroll(lines:-1,modifiers:0x42000)])
        check("disconnect releases own modifier",originals.releaseAll()==[.key(keyCode:62,pressed:false,modifiers:0)])
        check("release idempotent",originals.releaseAll().isEmpty)
        check("unknown packet does not trigger",HardwareTrigger.resolve(position:7,status:1)==nil && HardwareTrigger.resolve(position:0,status:4)==nil)
        var route=HardwareBindingRouter();let custom=UUID()
        check("original down owned",route.route("key.0",pressed:true,customBinding:nil) == .original)
        check("new mapping cannot steal original up",route.route("key.0",pressed:false,customBinding:custom) == .original)
        check("custom down replaces original",route.route("key.1",pressed:true,customBinding:custom) == .custom(custom))
        check("custom repeated down suppressed",route.route("key.1",pressed:true,customBinding:custom) == .consumed)
        check("disabled mapping cannot leak Return up",route.route("key.1",pressed:false,customBinding:nil) == .consumed)
        check("wheel dispatches each impulse",route.route("knob.left",pressed:true,customBinding:custom) == .custom(custom) && route.route("knob.left",pressed:true,customBinding:custom) == .custom(custom))
        check("wheel releases do not run macro",route.route("knob.left",pressed:false,customBinding:custom) == .consumed)
        _=route.route("key.2",pressed:true,customBinding:custom);route.reset()
        check("stale release after disconnect ignored",route.route("key.2",pressed:false,customBinding:nil) == .consumed)
        check("unknown trigger is consumed",route.route("unknown",pressed:true,customBinding:custom) == .consumed)
        try WorkflowValidation.validate([WorkflowStep(kind:.inputSource,argument:"com.apple.keylayout.ABC"),WorkflowStep(kind:.shortcut,keyCode:59)])
        check("input-source action validates",true)
        check("empty source rejected",rejects{try WorkflowValidation.validate([WorkflowStep(kind:.inputSource)])})
        check("control chars in source rejected",rejects{try WorkflowValidation.validate([WorkflowStep(kind:.inputSource,argument:"bad\nsource")])})
        check("unsafe URL rejected",rejects{try WorkflowValidation.validate([WorkflowStep(kind:.openURL,argument:"javascript:alert(1)")])})
        check("invalid key rejected",rejects{try WorkflowValidation.validate([WorkflowStep(kind:.shortcut,keyCode:128)])})
        check("retired action not executable",ActionKind(rawValue:"voiceAction")==nil)
        let data=try JSONEncoder().encode(bindings),roundTrip=try JSONDecoder().decode([WorkflowBinding].self,from:data)
        check("defaults round trip",roundTrip==bindings)
        let sources=InputSourceCatalog.available
        check("enabled input sources have stable identifiers",sources.allSatisfy{!$0.id.isEmpty && !$0.name.isEmpty} && Set(sources.map(\.id)).count==sources.count)
        let failed=rows.filter{$0["passed"] as? Bool == false}.count
        let report:[String:Any]=["status":failed==0 ? "PASS":"FAIL","checks":rows.count,"failed":failed,"cases":rows,"inputSourcesRead":sources.count,"inputSourceWrites":0,"HIDOpened":false,"hostKeysPosted":0]
        print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self));if failed>0 {exit(1)}
    }
}
