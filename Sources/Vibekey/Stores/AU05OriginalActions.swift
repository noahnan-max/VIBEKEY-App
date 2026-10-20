import AppKit
import ApplicationServices
import VibekeyCore

/// Host-side delivery of the user's existing six AU05 actions. Custom macros
/// are an additional, independently enabled feature; they do not own this path.
@MainActor final class AU05OriginalActions {
    private var router = OriginalDeviceActionRouter()
    private var onboardRouter = AU05OnboardActionRouter()
    private let source = CGEventSource(stateID:.privateState)
    private let authorized:()->Bool
    private let deliver:(CGEvent)->Void
    private let physicalModifiers:()->CGEventFlags
    private var deliveredKeys = Set<UInt16>()
    private(set) var keyEventCount = 0
    private(set) var scrollEventCount = 0
    var onFailure:((String)->Void)?
    var hasHeldModifier:Bool {AU05ShortcutKeyMap.modifiers.contains { deliveredKeys.contains($0.code) }}

    init(authorized:@escaping ()->Bool = {HostActions.accessibilityGranted},physicalModifiers:@escaping ()->CGEventFlags = {CGEventSource.flagsState(.hidSystemState)},deliver:@escaping (CGEvent)->Void = {$0.post(tap:.cghidEventTap)}) {
        self.authorized = authorized;self.physicalModifiers = physicalModifiers;self.deliver = deliver
    }
    func handle(_ id:String,pressed:Bool,physicalFlagsOverride:UInt64? = nil) {
        let events = router.handle(id,pressed:pressed,scrollLines:Int32(AU05ActionDefaults.scrollLines))
        guard !events.isEmpty else {return}
        guard authorized() else {
            router.releaseAll().forEach{post($0)};onFailure?("请允许辅助功能，以保留 AU05 的按键和滚轮动作。")
            return
        }
        events.forEach{post($0,physicalFlagsOverride:physicalFlagsOverride)}
    }
    func handleOnboard(_ id: String, pressed: Bool, configuration: AU05OnboardShortcut?, physicalFlagsOverride: UInt64? = nil) {
        let events = onboardRouter.handle(id, pressed: pressed, configuration: configuration)
        guard authorized() else { onboardRouter.releaseAll().forEach { post($0) }; return }
        events.forEach { post($0, physicalFlagsOverride: physicalFlagsOverride) }
    }
    func releaseAll() {router.releaseAll().forEach{post($0)};onboardRouter.releaseAll().forEach{post($0)}}
    /// Immediate detents bypass the macro single-flight gate, so quick rotation
    /// produces one scroll event for every received detent.
    func scroll(_ step:WorkflowStep,physicalFlagsOverride:UInt64? = nil) {
        guard step.kind == .scrollUp || step.kind == .scrollDown else { return }
        guard step.validationError == nil, authorized() else { onFailure?("请检查滚动幅度和辅助功能权限。");return }
        let lines = Int32(step.scrollLines) * (step.kind == .scrollUp ? 1 : -1)
        post(.scroll(lines:lines,modifiers:router.currentModifiers),physicalFlagsOverride:physicalFlagsOverride)
    }
    private func post(_ action:OriginalDeviceActionEvent,physicalFlagsOverride:UInt64? = nil) {
        let event:CGEvent?
        switch action {
        case .key(let code,let pressed,let modifiers):
            if !pressed,!deliveredKeys.contains(code) {return}
            event = CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:pressed)
            if AU05ShortcutKeyMap.modifiers.contains(where: { $0.code == code }) {event?.type = .flagsChanged}
            event?.flags = CGEventFlags(rawValue:modifiers).union(physicalFlagsOverride.map{CGEventFlags(rawValue:$0)} ?? physicalModifiers())
        case .scroll(let lines,let modifiers):
            event = CGEvent(scrollWheelEvent2Source:source,units:.line,wheelCount:1,wheel1:lines,wheel2:0,wheel3:0)
            event?.flags = CGEventFlags(rawValue:modifiers).union(physicalFlagsOverride.map{CGEventFlags(rawValue:$0)} ?? physicalModifiers())
        }
        guard let event else {onFailure?("AU05 动作暂未发送，请重试。");return}
        deliver(event)
        switch action {
        case .key(let code,let pressed,_):
            if pressed {deliveredKeys.insert(code)} else {deliveredKeys.remove(code)}
            keyEventCount += 1
        case .scroll:scrollEventCount += 1
        }
    }
}
