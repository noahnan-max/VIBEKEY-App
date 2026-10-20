import Foundation
import VibekeyCore

@main enum ShortcutCaptureChecks {
    static func main() throws {
        var count=0
        func check(_ value:Bool,_ name:String) {guard value else {fatalError(name)};count += 1}
        var capture=ShortcutCaptureSession()
        check(capture.keyDown(40,modifiers:0x120000) == .waiting && !capture.isActive,"Idle recorder captured a key")
        capture.begin()
        check(capture.keyDown(40,modifiers:0x120000) == .recorded(.init(keyCode:40,modifiers:0x120000)),"Command Shift K")
        check(capture.isActive && !capture.isCapturing,"Recorder did not drain held keys")
        check(capture.keyDown(40,modifiers:0x120000,isRepeat:true) == .waiting,"Repeat produced another capture")
        check(capture.keyUp(40,modifiers:0x120000) == .waiting && capture.isActive,"Modifier release was not drained")
        _ = capture.modifierChanged(56,modifiers:0x100000)
        check(capture.modifierChanged(55,modifiers:0) == .finished && !capture.isActive,"Full chord release")
        capture.begin();check(capture.keyDown(53,modifiers:0) == .cancelled && !capture.isActive,"Escape cancel")
        capture.begin();check(capture.keyDown(53,modifiers:0x100000) == .recorded(.init(keyCode:53,modifiers:0x100000)),"Modified Escape")
        capture.begin();check(capture.keyDown(0,modifiers:0) == .recorded(.init(keyCode:0,modifiers:0)),"Single normal key")
        check(capture.keyUp(0,modifiers:0) == .finished,"Single key release")
        capture.begin();_ = capture.modifierChanged(62,modifiers:0x40000)
        check(capture.modifierChanged(62,modifiers:0) == .recorded(.init(keyCode:62,modifiers:0)) && !capture.isActive,"Right Control tap")
        capture.begin();_ = capture.modifierChanged(63,modifiers:0x800000)
        check(capture.modifierChanged(63,modifiers:0) == .recorded(.init(keyCode:63,modifiers:0)),"Fn tap")
        capture.begin();_ = capture.modifierChanged(55,modifiers:0x100000);_ = capture.modifierChanged(56,modifiers:0x120000)
        check(capture.modifierChanged(56,modifiers:0x100000) == .recorded(.init(keyCode:56,modifiers:0x100000)),"Modifier-only chord")
        check(capture.modifierChanged(55,modifiers:0) == .finished,"Modifier-only drain")
        capture.begin();check(capture.keyDown(123,modifiers:0x820000) == .recorded(.init(keyCode:123,modifiers:0x20000)),"Implicit Fn on navigation key")
        check(capture.keyUp(123,modifiers:0x800000) == .finished && !capture.isActive,"Implicit Fn did not finish")
        capture.begin();check(capture.keyDown(40,modifiers:0x800000) == .recorded(.init(keyCode:40,modifiers:0x800000)),"Explicit Fn letter chord")
        capture.begin();check(capture.keyDown(200,modifiers:0) == .waiting && capture.isCapturing,"Unsupported code accepted")
        capture.cancel();check(!capture.isActive && capture.keyUp(200,modifiers:0) == .waiting,"Cancel clears ownership")
        check(RecordedShortcut(keyCode:8,modifiers:UInt64.max).modifiers == WorkflowValidation.allowedModifierMask,"Unsupported modifier bits")
        check(Set(ShortcutKeyCatalog.entries.map{$0.0}).count == ShortcutKeyCatalog.entries.count,"Duplicate key catalogue IDs")
        check(RecordedShortcut(keyCode:40,modifiers:0x120000).label == "⇧⌘K","Chord display")
        print("{\"status\":\"PASS\",\"checks\":\(count),\"systemInputPosted\":0}")
    }
}
