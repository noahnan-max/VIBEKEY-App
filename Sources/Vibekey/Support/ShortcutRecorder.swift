import AppKit
import SwiftUI
import VibekeyCore

struct ShortcutRecorder:NSViewRepresentable {
    let value:RecordedShortcut
    var identifier="shortcut.recorder"
    var placeholder:String? = nil
    var recorded:(RecordedShortcut)->Void
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context:Context)->ShortcutRecordingButton {ShortcutRecordingButton(frame:.zero)}
    func updateNSView(_ view:ShortcutRecordingButton,context:Context) {
        view.placeholder=placeholder;view.chord=value;view.onRecord=recorded;view.isEnabled=enabled
        view.setAccessibilityIdentifier(identifier)
        if !enabled {view.stopRecording()}
    }
    static func dismantleNSView(_ view:ShortcutRecordingButton,coordinator:()) {view.stopRecording()}
}

/// A local first responder, rather than a global shortcut or keyboard monitor.
final class ShortcutRecordingButton:NSButton {
    private static weak var activeRecorder:ShortcutRecordingButton?
    static var isAnyRecording:Bool {activeRecorder?.isRecording == true}
    var chord=RecordedShortcut(keyCode:0,modifiers:0) {didSet {refreshLabel()}}
    var placeholder:String? {didSet {refreshLabel()}}
    var onRecord:(RecordedShortcut)->Void={_ in}
    private var capture=ShortcutCaptureSession()
    private var mouseMonitor:Any?
    private var observers:[NSObjectProtocol]=[]
    var isRecording:Bool {capture.isActive}
    override var acceptsFirstResponder:Bool {true}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    override var intrinsicContentSize:NSSize {NSSize(width:super.intrinsicContentSize.width+20,height:34)}

    override init(frame:NSRect) {
        super.init(frame:frame)
        bezelStyle = .rounded;isBordered=false;setButtonType(.momentaryPushIn)
        font = .systemFont(ofSize:12.5);image=NSImage(systemSymbolName:"keyboard",accessibilityDescription:nil)
        imagePosition = .imageLeft;target=self;action=#selector(toggleRecording)
        setContentHuggingPriority(.defaultLow,for:.horizontal)
        setAccessibilityLabel("录制快捷键")
        setAccessibilityHelp("点击后按组合键，Esc 取消；也可以展开手动设置。")
        toolTip="按组合键自动填入，Esc 取消；系统保留的组合可用手动设置。"
        refreshLabel()
    }
    required init?(coder:NSCoder) {return nil}

    override func draw(_ dirtyRect:NSRect) {
        let focused=window?.firstResponder === self
        let shape=NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:VIFLOWTheme.controlRadius,yRadius:VIFLOWTheme.controlRadius)
        (isRecording ? VIFLOWTheme.accentSoftNSColor : isHighlighted ? VIFLOWTheme.mutedNSColor : VIFLOWTheme.surfaceNSColor).setFill()
        shape.fill()
        (isEnabled && (isRecording || focused) ? VIFLOWTheme.accentNSColor : VIFLOWTheme.controlBorderNSColor).setStroke()
        shape.lineWidth=isEnabled && (isRecording || focused) ? 1.5:1
        shape.stroke()
        super.draw(dirtyRect)
    }
    override func becomeFirstResponder()->Bool {let accepted=super.becomeFirstResponder();needsDisplay=true;return accepted}

    @objc private func toggleRecording() {
        if capture.isActive {stopRecording();return}
        guard isEnabled,window?.makeFirstResponder(self) == true else {return}
        Self.activeRecorder?.stopRecording()
        Self.activeRecorder=self;capture.begin();refreshLabel()
        mouseMonitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) {[weak self] event in
            guard let self else {return event}
            if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow,from:nil)) {self.stopRecording()}
            return event
        }
        for (name,object) in [(NSApplication.didResignActiveNotification,NSApp as Any?),(NSWindow.didResignKeyNotification,window as Any?)] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:object,queue:.main) {[weak self] _ in
                Task {@MainActor in self?.stopRecording()}
            })
        }
    }
    func stopRecording(releaseFocus:Bool=true) {
        capture.cancel()
        if Self.activeRecorder === self {Self.activeRecorder=nil}
        if let mouseMonitor {NSEvent.removeMonitor(mouseMonitor)};mouseMonitor=nil
        observers.forEach{NotificationCenter.default.removeObserver($0)};observers.removeAll()
        refreshLabel()
        if releaseFocus,window?.firstResponder === self {_ = window?.makeFirstResponder(nil)}
    }
    override func resignFirstResponder()->Bool {stopRecording(releaseFocus:false);return super.resignFirstResponder()}
    override func viewWillMove(toWindow newWindow:NSWindow?) {if newWindow !== window {stopRecording()};super.viewWillMove(toWindow:newWindow)}
    override func performKeyEquivalent(with event:NSEvent)->Bool {
        guard capture.isActive,window?.firstResponder === self else {return super.performKeyEquivalent(with:event)}
        process(event);return true
    }
    override func keyDown(with event:NSEvent) {if capture.isActive {process(event)} else {super.keyDown(with:event)}}
    override func keyUp(with event:NSEvent) {if capture.isActive {process(event)} else {super.keyUp(with:event)}}
    override func flagsChanged(with event:NSEvent) {if capture.isActive {process(event)} else {super.flagsChanged(with:event)}}
    private func process(_ event:NSEvent) {
        let result:ShortcutCaptureResult
        switch event.type {
        case .keyDown:result=capture.keyDown(event.keyCode,modifiers:UInt64(event.modifierFlags.rawValue),isRepeat:event.isARepeat)
        case .keyUp:result=capture.keyUp(event.keyCode,modifiers:UInt64(event.modifierFlags.rawValue))
        case .flagsChanged:result=capture.modifierChanged(event.keyCode,modifiers:UInt64(event.modifierFlags.rawValue))
        default:return
        }
        if case .recorded(let value)=result {chord=value;onRecord(value)}
        if !capture.isActive {stopRecording()} else {refreshLabel()}
    }
    private func refreshLabel() {
        title=capture.isCapturing ? "请按组合键…  Esc 取消" : capture.isActive ? chord.label+"  ✓" : placeholder ?? chord.label+"  ·  点击录制"
        let ink=capture.isActive ? VIFLOWTheme.accentNSColor : placeholder == nil ? VIFLOWTheme.inkNSColor : VIFLOWTheme.secondaryNSColor
        attributedTitle=NSAttributedString(string:title,attributes:[.font:NSFont.systemFont(ofSize:12.5,weight:.medium),.foregroundColor:ink])
        contentTintColor=capture.isActive ? VIFLOWTheme.accentNSColor:VIFLOWTheme.secondaryNSColor
        setAccessibilityValue(capture.isCapturing ? "正在录制":placeholder ?? chord.label)
        needsDisplay=true
    }
}
