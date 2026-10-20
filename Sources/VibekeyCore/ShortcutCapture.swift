import Foundation

public struct RecordedShortcut: Equatable {
    public let keyCode: UInt16
    public let modifiers: UInt64
    public init(keyCode:UInt16,modifiers:UInt64) {
        self.keyCode=keyCode;self.modifiers=modifiers & WorkflowValidation.allowedModifierMask
    }
    public var label:String {
        let symbols:[(UInt64,String)]=[(0x00040000,"⌃"),(0x00080000,"⌥"),(0x00020000,"⇧"),(0x00100000,"⌘"),(0x00800000,"fn ")]
        let prefix=symbols.filter{modifiers & $0.0 != 0}.map(\.1).joined()
        let name=ShortcutKeyCatalog.entries.first{$0.0 == keyCode}?.1.replacingOccurrences(of:"（单键）",with:"") ?? "键码 \(keyCode)"
        return prefix+name
    }
}

public enum ShortcutCaptureResult:Equatable {
    case waiting, cancelled, finished, recorded(RecordedShortcut)
}

/// Input is provided only by the armed recorder's first responder. No event is
/// posted, and neither typed characters nor an event history are retained.
public struct ShortcutCaptureSession {
    public private(set) var isActive=false
    public private(set) var isCapturing=false
    private var heldKey:UInt16?
    private var pendingModifier:RecordedShortcut?
    private var implicitFlags:UInt64=0
    public init() {}
    public mutating func begin() {cancel();isActive=true;isCapturing=true}
    public mutating func cancel() {isActive=false;isCapturing=false;heldKey=nil;pendingModifier=nil;implicitFlags=0}
    public mutating func keyDown(_ code:UInt16,modifiers:UInt64,isRepeat:Bool=false)->ShortcutCaptureResult {
        guard isActive,isCapturing,!isRepeat,code<=127 else {return .waiting}
        var flags=modifiers & WorkflowValidation.allowedModifierMask
        // AppKit also marks navigation/F keys as function keys without an Fn press.
        if ShortcutKeyCatalog.functionKeys.contains(code) {implicitFlags=flags & 0x00800000;flags &= ~implicitFlags}
        if code == 53,flags == 0 {cancel();return .cancelled}
        return record(RecordedShortcut(keyCode:code,modifiers:flags),held:code,currentFlags:flags)
    }
    public mutating func keyUp(_ code:UInt16,modifiers:UInt64)->ShortcutCaptureResult {
        guard isActive,!isCapturing else {return .waiting}
        if heldKey == code {heldKey=nil}
        return finishIfReleased(modifiers)
    }
    public mutating func modifierChanged(_ code:UInt16,modifiers:UInt64)->ShortcutCaptureResult {
        guard isActive else {return .waiting}
        let flags=modifiers & WorkflowValidation.allowedModifierMask
        guard isCapturing else {return finishIfReleased(flags)}
        if code == 57 {return record(RecordedShortcut(keyCode:code,modifiers:flags),held:nil,currentFlags:flags)}
        let masks:[UInt16:UInt64]=[59:0x40000,62:0x40000,56:0x20000,60:0x20000,58:0x80000,61:0x80000,55:0x100000,54:0x100000,63:0x800000]
        guard let own=masks[code] else {return .waiting}
        if flags & own != 0 {
            pendingModifier=RecordedShortcut(keyCode:code,modifiers:flags & ~own)
            return .waiting
        }
        guard let pending=pendingModifier,pending.keyCode == code else {return .waiting}
        return record(pending,held:nil,currentFlags:flags)
    }
    private mutating func record(_ value:RecordedShortcut,held:UInt16?,currentFlags:UInt64)->ShortcutCaptureResult {
        isCapturing=false;heldKey=held;pendingModifier=nil
        _ = finishIfReleased(currentFlags)
        return .recorded(value)
    }
    private mutating func finishIfReleased(_ flags:UInt64)->ShortcutCaptureResult {
        guard heldKey == nil,flags & WorkflowValidation.allowedModifierMask & ~implicitFlags == 0 else {return .waiting}
        cancel();return .finished
    }
}

public enum ShortcutKeyCatalog {
    public static let functionKeys:Set<UInt16>=[122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90,123,124,125,126,115,119,116,121,114,117]
    public static let entries: [(UInt16,String)] = [
        (0,"A"),(11,"B"),(8,"C"),(2,"D"),(14,"E"),(3,"F"),(5,"G"),(4,"H"),(34,"I"),(38,"J"),(40,"K"),(37,"L"),(46,"M"),
        (45,"N"),(31,"O"),(35,"P"),(12,"Q"),(15,"R"),(1,"S"),(17,"T"),(32,"U"),(9,"V"),(13,"W"),(7,"X"),(16,"Y"),(6,"Z"),
        (29,"0"),(18,"1"),(19,"2"),(20,"3"),(21,"4"),(23,"5"),(22,"6"),(26,"7"),(28,"8"),(25,"9"),
        (59,"左 Control（单键）"),(62,"右 Control（单键）"),(58,"Option（单键）"),(56,"Shift（单键）"),(55,"Command（单键）"),
        (36,"Return"),(48,"Tab"),(49,"Space"),(51,"Delete"),(117,"Forward Delete"),(53,"Esc"),
        (123,"←"),(124,"→"),(125,"↓"),(126,"↑"),(115,"Home"),(119,"End"),(116,"Page Up"),(121,"Page Down"),
        (122,"F1"),(120,"F2"),(99,"F3"),(118,"F4"),(96,"F5"),(97,"F6"),(98,"F7"),(100,"F8"),(101,"F9"),(109,"F10"),
        (103,"F11"),(111,"F12"),(105,"F13"),(107,"F14"),(113,"F15"),(106,"F16"),(64,"F17"),(79,"F18"),(80,"F19"),(90,"F20"),
        (27,"−"),(24,"="),(33,"["),(30,"]"),(42,"\\"),(41,";"),(39,"'"),(43,","),(47,"."),(44,"/")
    ] + [(54,"右 Command（单键）"),(60,"右 Shift（单键）"),(61,"右 Option（单键）"),(63,"Fn（单键）"),(57,"Caps Lock"),(50,"`"),(65,"小键盘 ."),(67,"小键盘 *"),(69,"小键盘 +"),(71,"小键盘 Clear"),(75,"小键盘 /"),(76,"小键盘 Enter"),(78,"小键盘 −"),(81,"小键盘 ="),(82,"小键盘 0"),(83,"小键盘 1"),(84,"小键盘 2"),(85,"小键盘 3"),(86,"小键盘 4"),(87,"小键盘 5"),(88,"小键盘 6"),(89,"小键盘 7"),(91,"小键盘 8"),(92,"小键盘 9")]
}
