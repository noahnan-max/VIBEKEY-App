import AppKit
import Foundation
import VibekeyCore

@main @MainActor enum RecorderWidgetChecks {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var checks=0
        func check(_ value:Bool,_ name:String) {guard value else {fatalError(name)};checks += 1}
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("shortcut-recorder-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=WorkflowStore(directory:directory),saved=store.activeBindings
        let bytes=try Data(contentsOf:directory.appendingPathComponent("workflows.json"))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:200),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        defer {window.contentView=nil;window.close()}
        let root=NSView(frame:window.contentView!.bounds);window.contentView=root
        let button=ShortcutRecordingButton(frame:NSRect(x:10,y:10,width:600,height:34));root.addSubview(button)
        var records:[RecordedShortcut]=[]
        button.onRecord={value in
            records.append(value)
            store.bindings[0].steps=[WorkflowStep(kind:.shortcut,keyCode:value.keyCode,modifiers:value.modifiers)]
        }
        func event(_ type:NSEvent.EventType,_ code:UInt16,_ flags:UInt=0,_ repeatKey:Bool=false)->NSEvent {
            NSEvent.keyEvent(with:type,location:.zero,modifierFlags:NSEvent.ModifierFlags(rawValue:flags),timestamp:0,
                             windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:repeatKey,keyCode:code)!
        }
        button.performClick(nil)
        check(button.isRecording && window.firstResponder === button,"Recorder was not focused")
        check(button.performKeyEquivalent(with:event(.keyDown,12,0x100000)),"Command Q was not consumed by recorder")
        check(records == [.init(keyCode:12,modifiers:0x100000)],"Native Command Q capture")
        _ = button.performKeyEquivalent(with:event(.keyDown,12,0x100000,true))
        check(records.count==1 && button.isRecording,"Repeat escaped release drain")
        button.keyUp(with:event(.keyUp,12,0x100000));check(button.isRecording,"Stopped before Command was released")
        button.flagsChanged(with:event(.flagsChanged,55,0));check(!button.isRecording && !ShortcutRecordingButton.isAnyRecording,"Recorder leaked after release")
        let afterRecording=try Data(contentsOf:directory.appendingPathComponent("workflows.json"))
        check(store.bindings != saved && store.activeBindings==saved && afterRecording==bytes,"Recorded draft auto-activated or saved")
        button.performClick(nil);button.keyDown(with:event(.keyDown,53))
        check(!button.isRecording && records.count==1,"Escape changed binding or kept recording")
        button.performClick(nil);button.flagsChanged(with:event(.flagsChanged,62,0x40000));button.flagsChanged(with:event(.flagsChanged,62))
        check(records.last == .init(keyCode:62,modifiers:0) && !button.isRecording,"Native right Control tap")
        button.performClick(nil);button.removeFromSuperview()
        check(!button.isRecording && !ShortcutRecordingButton.isAnyRecording,"Removed view kept recording")
        root.addSubview(button);button.performClick(nil);button.stopRecording();button.stopRecording()
        check(!button.isRecording && records.count==2,"Repeated cleanup changed recorded data")
        check(!window.isVisible,"Offscreen unit window was shown")
        print("{\"status\":\"PASS\",\"checks\":\(checks),\"systemInputPosted\":0,\"windowShown\":false}")
    }
}
