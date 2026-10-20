import AppKit
import ApplicationServices
import Combine
import VibekeyCore

@MainActor struct RadialHostTarget {
    let processID:pid_t
    let isCurrent:()->Bool
    static func capture()->Self? {
        guard let application = NSWorkspace.shared.frontmostApplication,!application.isTerminated else {return nil}
        let pid = application.processIdentifier,root = AXUIElementCreateApplication(application.processIdentifier)
        var window:CFTypeRef?
        let status = AXUIElementCopyAttributeValue(root,kAXFocusedWindowAttribute as CFString,&window)
        guard status == .success || status == .noValue || status == .attributeUnsupported else {return nil}
        var element:CFTypeRef?
        let elementStatus = AXUIElementCopyAttributeValue(root,kAXFocusedUIElementAttribute as CFString,&element)
        guard elementStatus == .success || elementStatus == .noValue || elementStatus == .attributeUnsupported else {return nil}
        return Self(processID:pid,isCurrent:{
            guard !application.isTerminated,NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {return false}
            var current:CFTypeRef?
            let result = AXUIElementCopyAttributeValue(root,kAXFocusedWindowAttribute as CFString,&current)
            guard result == status else {return false}
            if let window,let current {guard CFEqual(window,current) else {return false}}
            else if window != nil || current != nil {return false}
            var currentElement:CFTypeRef?
            let currentElementStatus = AXUIElementCopyAttributeValue(root,kAXFocusedUIElementAttribute as CFString,&currentElement)
            guard currentElementStatus == elementStatus else {return false}
            if let element,let currentElement {return CFEqual(element,currentElement)}
            return element == nil && currentElement == nil
        })
    }
}

/// One input owner before original key/scroll, preset and macro dispatch. The
/// panel never takes keyboard focus. Preview follows the same gesture kernel,
/// but its execute effect cannot reach HostActions.
@MainActor final class RadialMenuController:ObservableObject {
    @Published private(set) var presentation:RadialPresentation?
    @Published private(set) var previewMode = false
    @Published private(set) var executing = false
    @Published private(set) var message:String?
    var isPresented:Bool {presentation != nil}
    var activation:RadialActivation {previewMode ? store.draft.activation:store.configuration.activation}
    var hasPendingHold:Bool {router.pendingHold != nil}
    var presentationGeometry:(visible:Bool,key:Bool,main:Bool,frame:NSRect)? {overlay?.geometry}
    var forward:((String,Bool)->Void)?
    var replayMiddleTap:((UInt64)->Void)?
    var replayTap:((String,UInt64)->Void)?
    var hardwareEligible:()->Bool = {false}
    var previewEligible:()->Bool = {true}
    var onLog:((String)->Void)?
    private let store:RadialMenuStore
    private var router = RadialGestureRouter()
    private var holdTask:Task<Void,Never>?
    private var holdToken:RadialHoldToken?
    private var actionTask:Task<Void,Never>?
    private var target:RadialHostTarget?
    private var targetSession:RadialHoldToken?
    private var subscriptions:Set<AnyCancellable> = []
    private var focusObserver:NSObjectProtocol?
    private var outsideMonitor:Any?
    private var localMonitor:Any?
    private var overlay:RadialMenuOverlay?
    private var previewConsumed:Set<String>=[]
    private var previewConfirmationIndex:Int?
    private let clock:()->TimeInterval
    private let modifiers:()->UInt64
    private let captureTarget:()->RadialHostTarget?
    private let executeAction:(([WorkflowStep])async throws->Void)?
    private let showsPanel:Bool
    private let observeWorkspace:Bool
    private var finished = false
    private let windowOverview = WindowOverviewController()

    init(store:RadialMenuStore,showsPanel:Bool = true,observeWorkspace:Bool = true,
         clock:@escaping ()->TimeInterval = {ProcessInfo.processInfo.systemUptime},
         modifiers:@escaping ()->UInt64 = {CGEventSource.flagsState(.hidSystemState).rawValue},
         captureTarget:(()->RadialHostTarget?)? = nil,
         executeAction:(([WorkflowStep])async throws->Void)? = nil) {
        self.store = store;self.clock = clock;self.modifiers = modifiers;self.captureTarget = captureTarget ?? {RadialHostTarget.capture()};self.showsPanel = showsPanel
        self.executeAction = executeAction
        self.observeWorkspace = observeWorkspace
        _ = try? router.configure(store.configuration)
        store.$configuration.dropFirst().sink {[weak self] document in
            guard let self else {return}
            self.cancel(reason:.configurationChanged)
            self.apply((try? self.router.configure(document)) ?? [])
        }.store(in:&subscriptions)
        store.$isReady.dropFirst().sink {[weak self] ready in
            if !ready {self?.cancel(reason:.configurationChanged)}
        }.store(in:&subscriptions)
    }
    /// Install AppKit event monitors only after NSApplication finishes launch.
    /// Installing them while SwiftUI constructs App/runtime breaks normal mouse
    /// delivery on macOS. Construction must have no workspace/event side effects.
    func startObservingWorkspace() {
        guard observeWorkspace,!finished,localMonitor == nil else {return}
            focusObserver = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) {[weak self] _ in
                guard let owner = self else {return}
                Task {@MainActor in
                    guard owner.isPresented || owner.hasPendingHold else {return}
                    if owner.previewMode || owner.target?.isCurrent() != true {owner.cancel(reason:.targetChanged)}
                }
            }
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) {[weak self] _ in
                guard let owner = self else {return}
                Task {@MainActor in guard owner.isPresented || owner.hasPendingHold else {return};owner.cancel(reason:.windowClosed)}
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.keyDown]) {[weak self] event in
                guard let self,self.isPresented || self.hasPendingHold else {return event}
                if event.type == .keyDown,event.keyCode == 53 {self.cancel();return nil}
                if event.type != .keyDown,event.window !== self.overlay?.panel {self.cancel(reason:.windowClosed)}
                return event
            }
    }
    private var eligible:Bool {
        if previewMode {return previewEligible()}
        let mask:UInt64 = 0x00100000 | 0x00080000 | 0x00040000 | 0x00020000 | 0x00800000
        return store.isReady && hardwareEligible() && !executing && modifiers() & mask == 0 && (target?.isCurrent() ?? true)
    }
    func handleHardware(_ id:String,pressed:Bool) {
        guard !finished else {return}
        if windowOverview.handleHardware(id,pressed:pressed,eligible:hardwareEligible() && modifiers() & 0x009e0000 == 0) {return}
        if !pressed,previewConsumed.remove(id) != nil {
            if (id == "knob.press" || (store.draft.enabled && id == activation.triggerID)),previewMode,previewConfirmationIndex == presentation?.selectedIndex {confirm()}
            previewConfirmationIndex=nil
            return
        }
        if previewMode,previewEligible() {
            if id == "knob.left" || id == "knob.right" {if pressed {rotate(id == "knob.left" ? -1:1)};return}
            if (id == "knob.press" || (store.draft.enabled && id == activation.triggerID)),pressed {
                if previewConsumed.insert(id).inserted {previewConfirmationIndex=presentation?.selectedIndex}
                return
            }
            if id == activation.cancelTriggerID,pressed {previewConsumed.insert(id);cancel();return}
            if !pressed {apply(router.handle(id:id,pressed:false,now:clock(),eligible:false,modifiers:modifiers()));return}
        }
        if previewMode {cancel()}
        let trigger = store.configuration.activation.triggerID
        if id == trigger,pressed,store.configuration.enabled,!previewMode,!isPresented,!hasPendingHold,eligible {
            target = captureTarget()
        }
        let canUse = eligible && (previewMode || target != nil || (id != trigger && !hasPendingHold && !isPresented))
        apply(router.handle(id:id,pressed:pressed,now:clock(),eligible:canUse,modifiers:modifiers()))
    }
    func showPreview() {
        guard !finished,!executing,previewEligible() else {message = "请结束当前工作流后预览。";return}
        do {
            try RadialMenuValidation.validate(store.draft)
            let view = try RadialPresentation(session:RadialHoldToken(session:UUID(),press:0),items:store.draft.items)
            cancel()
            previewMode = true;presentation = view
            presentOverlay()
            message = "预览中：转动旋钮或点选，确认只查看，不执行动作。"
        } catch {cancel();message = error.localizedDescription}
    }
    /// Explicit settings action; unlike preview, this opens the real system UI.
    func testWindowOverview() {
        guard !finished,!executing,!isPresented,!hasPendingHold,previewEligible(),store.flushAutomaticSave() else {return}
        executing = true
        actionTask = Task { [weak self] in
            guard let self else {return}
            defer {self.executing = false;self.actionTask = nil}
            do {
                try await windowOverview.run(cancelTriggerID:activation.cancelTriggerID)
                message = windowOverview.confirmed ? "已切换到所选窗口。" : "窗口总览已关闭。"
            } catch {message = error is CancellationError ? "窗口总览已取消。" : error.localizedDescription}
        }
    }
    func rotate(_ delta:Int) {
        guard let presentation else {return}
        let index = (presentation.selectedIndex + delta % presentation.totalCount + presentation.totalCount) % presentation.totalCount
        select(index)
    }
    func select(_ index:Int) {
        if previewMode,let view = presentation {
            if let next = try? RadialPresentation(session:view.session,items:view.allItems,selectedIndex:index) {presentation = next}
        } else {apply(router.select(index:index,eligible:eligible))}
    }
    func confirm() {
        if previewMode,let view = presentation {
            let name = view.selectedItem.name;cancel();message = "预览选择："+name+"（未执行）"
        } else {apply(router.confirm(eligible:eligible))}
    }
    func chooseFromDiagram(session:RadialHoldToken,preview:Bool,index:Int) {
        guard let view = presentation,view.session == session,previewMode == preview,
              view.allItems.indices.contains(index) else {return}
        select(index)
        guard !preview,presentation?.session == session,presentation?.selectedIndex == index else {return}
        confirm()
    }
    func dismissFromDiagram(session:RadialHoldToken) {
        guard presentation?.session == session else {return}
        cancel()
    }
    func cancel(reason:RadialDismissReason = .cancelled) {
        windowOverview.cancel()
        actionTask?.cancel()
        apply(router.reset(reason:reason))
        holdTask?.cancel();holdTask = nil;holdToken = nil
        presentation = nil;overlay?.hide();target = nil;targetSession = nil;previewConfirmationIndex=nil
        let wasPreview = previewMode;previewMode = false
        if wasPreview {_ = try? router.configure(store.configuration)}
    }
    func shutdown() {
        finished = true;cancel(reason:.disconnected);windowOverview.shutdown();actionTask?.cancel();overlay?.close();overlay = nil;subscriptions.removeAll()
        if let focusObserver {NSWorkspace.shared.notificationCenter.removeObserver(focusObserver)}
        if let outsideMonitor {NSEvent.removeMonitor(outsideMonitor)}
        if let localMonitor {NSEvent.removeMonitor(localMonitor)}
        focusObserver = nil;outsideMonitor = nil;localMonitor = nil
    }
    func prepareForExit() async {store.flushAutomaticSave();cancel(reason:.windowClosed);actionTask?.cancel();await actionTask?.value}
    private func presentOverlay() {
        guard showsPanel else {return}
        if overlay == nil {overlay = RadialMenuOverlay(controller:self)}
        overlay?.show(at:NSEvent.mouseLocation)
    }
    private func apply(_ effects:[RadialGestureEffect]) {
        for effect in effects {
            switch effect {
            case .forward(let id,let pressed):forward?(id,pressed)
            case .replayMiddleTap(let flags):replayMiddleTap?(flags);target = nil;targetSession = nil
            case .replayTap(let id,let flags):replayTap?(id,flags);target = nil;targetSession = nil
            case .scheduleHold(let token,let deadline):
                holdTask?.cancel();holdToken = token
                let delay = max(0,deadline-clock())
                holdTask = Task {[weak self] in
                    do {try await Task.sleep(nanoseconds:UInt64(min(delay,1)*1_000_000_000))} catch {return}
                    guard let self,!Task.isCancelled,self.holdToken == token else {return}
                    self.apply(self.router.holdFired(token:token,now:self.clock(),eligible:self.eligible && (self.previewMode || self.target != nil)))
                }
            case .cancelHold(let token):
                if holdToken == token {holdTask?.cancel();holdTask = nil;holdToken = nil}
            case .show(let view):
                targetSession = view.session;presentation = view
                presentOverlay()
            case .move(let view):presentation = view
            case .dismiss(_,let reason):
                presentation = nil;overlay?.hide()
                if reason != .confirmed {target = nil;targetSession = nil;previewMode = false}
            case .execute(let session,let item):
                guard targetSession == session else {continue}
                let wasPreview = previewMode,frozenTarget = target
                target = nil;targetSession = nil;previewMode = false
                if wasPreview {
                    _ = try? router.configure(store.configuration)
                    message = "预览选择："+item.name+"（未执行）";continue
                }
                guard store.isReady,!executing,hardwareEligible(),let frozenTarget,frozenTarget.isCurrent() else {message = "输入位置已变化，动作未执行。";continue}
                executing = true;message = "正在执行："+item.name
                actionTask = Task {[weak self] in
                    guard let self else {return}
                    defer {self.executing = false;self.actionTask = nil}
                    do {
                        try Task.checkCancellation()
                        guard self.store.isReady,self.hardwareEligible(),frozenTarget.isCurrent() else {throw RadialMenuError.invalid("输入位置或设备状态已变化，动作未执行。")}
                        try RadialMenuValidation.validate(RadialMenuDocument(items:[item]))
                        if WindowOverviewAction.matches(item.steps), self.executeAction == nil {
                            try await self.windowOverview.run(cancelTriggerID:self.activation.cancelTriggerID)
                            self.message = self.windowOverview.confirmed ? "已切换到所选窗口。" : "窗口总览已关闭。"
                            return
                        } else if let executeAction = self.executeAction {
                            try await executeAction(item.steps)
                        } else {
                            try await HostActions().run(item.steps,log:{_ in})
                        }
                        try Task.checkCancellation()
                        self.message = "已执行："+item.name;self.onLog?("轮盘动作执行完成")
                    } catch {self.message = error is CancellationError ? "轮盘动作已取消。" : error.localizedDescription}
                }
            }
        }
        if router.pendingHold == nil,router.presentation == nil,presentation == nil {
            target = nil;targetSession = nil
        }
    }
}
