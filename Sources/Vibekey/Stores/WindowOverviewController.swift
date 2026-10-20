import AppKit
import ApplicationServices
import SwiftUI
import VibekeyCore

struct WindowOverviewSnapshot {
    let visible: Bool
    let targets: [WindowOverviewTarget]
}

/// Temporary owner of the AU05 inputs while the system's own overview is open.
/// The adapter is injectable; construction performs no AX query or UI action.
@MainActor final class WindowOverviewController: ObservableObject {
    struct Adapter {
        var permitted: () -> Bool
        var open: () async throws -> Void
        var snapshot: () -> WindowOverviewSnapshot
        var highlight: (WindowOverviewTarget) throws -> Void
        var confirm: (UInt32) async throws -> Void
        var cancel: () -> Void
    }
    private let adapter: Adapter
    private let sleep: () async throws -> Void
    private let clock: () -> TimeInterval
    private var input = WindowOverviewInputRouter()
    private var selection = WindowOverviewSelection()
    private var session: UUID?
    private var confirmation: Task<Void, Never>?
    private var failure: Error?
    private var confirming = false
    private let showsPanel: Bool
    private var panel: WindowOverviewPanel?
    @Published private(set) var ordinal = 0
    @Published private(set) var windowCount = 0
    @Published private(set) var cancelKeyTitle = "下键"
    private(set) var confirmed = false
    var isActive: Bool { session != nil }
    var selectedID: UInt32? { selection.selectedID }

    init(adapter: Adapter? = nil, showsPanel: Bool = true,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 100_000_000) }) {
        self.adapter = adapter ?? MissionControlAccessibility().adapter
        self.clock = clock; self.sleep = sleep; self.showsPanel = showsPanel
    }
    func run(cancelTriggerID: String) async throws {
        guard !isActive else { throw WindowOverviewFailure("窗口总览已经打开。") }
        guard adapter.permitted() else { throw WorkflowError.accessibilityRequired }
        let token = UUID(), began = clock()
        session = token; failure = nil; confirmed = false; confirming = false
        cancelKeyTitle = cancelTriggerID == "key.0" ? "上键" : "下键"
        input.begin(cancelTriggerID: cancelTriggerID)
        defer { if session == token { finish(closeSystem: false) } }
        do {
            try await adapter.open()
            var initial: WindowOverviewSnapshot?
            for _ in 0..<20 {
                try Task.checkCancellation()
                guard session == token else { return }
                let snapshot = adapter.snapshot()
                if snapshot.visible, !snapshot.targets.isEmpty { initial = snapshot; break }
                try await sleep()
            }
            guard let initial else { throw WindowOverviewFailure("已请求系统窗口总览，但未读取到可选择的缩略窗口。可直接用鼠标选择。") }
            selection.begin(initial.targets)
            guard let id = selection.selectedID, let first = selection.resolve(id, current: initial.targets) else {
                throw WindowOverviewFailure("当前总览没有可确认的窗口。")
            }
            try adapter.highlight(first)
            updateSelectionDisplay()
            if showsPanel {
                if panel == nil { panel = WindowOverviewPanel(controller: self) }
                panel?.show()
            }
            while session == token {
                try Task.checkCancellation()
                guard adapter.permitted() else { throw WorkflowError.accessibilityRequired }
                guard clock() - began < 60 else { finish(closeSystem: true); return }
                if !confirming, !adapter.snapshot().visible { finish(closeSystem: false); return }
                try await sleep()
            }
            if let failure { throw failure }
        } catch {
            if session == token { finish(closeSystem: error is CancellationError) }
            throw error
        }
    }
    /// Called before the normal wheel router, including after cancellation to
    /// drain releases which still belong to this interaction.
    func handleHardware(_ id: String, pressed: Bool, eligible: Bool) -> Bool {
        let result = input.handle(id, pressed: pressed, selectedID: selection.selectedID,
                                  eligible: eligible && adapter.permitted())
        guard result.consumed else { return false }
        guard !confirming else { return true }
        switch result.effect {
        case .rotate(let delta): rotate(delta)
        case .confirm(let id): confirm(id)
        case .cancel: finish(closeSystem: true)
        case nil: break
        }
        return true
    }
    func rotate(_ delta: Int) {
        guard isActive, !confirming, adapter.permitted() else { return }
        // Encoder events can arrive while the system is still animating open.
        // They belong to this session, but must not end it before the first read.
        guard selection.selectedID != nil else { return }
        let snapshot = adapter.snapshot()
        guard snapshot.visible, let target = selection.rotate(delta, current: snapshot.targets) else { finish(closeSystem: false); return }
        do { try adapter.highlight(target); updateSelectionDisplay() }
        catch { failure = error; finish(closeSystem: false) }
    }
    func confirmSelection() { if let id = selection.selectedID { confirm(id) } }
    private func confirm(_ id: UInt32) {
            guard isActive, !confirming else { return }
            let snapshot = adapter.snapshot()
            guard snapshot.visible, selection.resolve(id, current: snapshot.targets) != nil else {
                failure = WindowOverviewFailure("所选窗口已关闭或总览已改变，没有切换到其他窗口。")
                finish(closeSystem: false); return
            }
            let token = session
            confirming = true
            confirmation = Task { [weak self] in
                guard let self else { return }
                do {
                    try Task.checkCancellation()
                    try await adapter.confirm(id)
                    guard session == token else { return }
                    confirmed = true; finish(closeSystem: false)
                } catch {
                    guard session == token else { return }
                    failure = error; finish(closeSystem: false)
                }
            }
    }
    func cancel() { confirmation?.cancel(); finish(closeSystem: true) }
    func shutdown() { cancel(); panel?.close(); panel = nil }
    private func updateSelectionDisplay() {
        windowCount = selection.targets.count
        ordinal = selection.targets.firstIndex(where: { $0.id == selection.selectedID }).map { $0 + 1 } ?? 0
    }
    private func finish(closeSystem: Bool) {
        let wasActive = isActive
        session = nil; input.end(); selection.end(); confirming = false; confirmation = nil
        panel?.hide(); updateSelectionDisplay()
        if wasActive, closeSystem { adapter.cancel() }
    }
}

@MainActor private final class WindowOverviewPanel {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private let panel: Panel
    init(controller: WindowOverviewController) {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 76),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        let view = RadialScrollHostingView(rootView: WindowOverviewHint(controller: controller))
        view.rotate = { [weak controller] in controller?.rotate($0) }
        panel.contentView = view
    }
    func show() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 260, y: screen.visibleFrame.minY + 24))
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
    func close() { panel.contentView = nil; panel.close() }
}

private struct WindowOverviewHint: View {
    @ObservedObject var controller: WindowOverviewController
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "macwindow.on.rectangle").foregroundColor(VIFLOWTheme.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text("窗口总览  \(controller.ordinal) / \(controller.windowCount)").font(VIFLOWTheme.subheading)
                Text("转动旋钮选择 · 按下确认 · \(controller.cancelKeyTitle)或 Esc 取消").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
            }
            Spacer(minLength: 0)
            Button("取消") { controller.cancel() }.accessibilityIdentifier("vibekey.window-overview.cancel")
            Button("确认") { controller.confirmSelection() }.buttonStyle(VIFLOWPrimaryButtonStyle())
                .accessibilityIdentifier("vibekey.window-overview.confirm")
        }.padding(16).frame(width: 520, height: 76)
            .background(VIFLOWTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(VIFLOWTheme.controlBorder))
            .font(VIFLOWTheme.body).foregroundColor(VIFLOWTheme.ink)
    }
}

/// Reads only the Mission Control subtree. The string identifiers are observed
/// macOS UI structure, so unsupported layouts fail closed rather than guessing.
@MainActor private final class MissionControlAccessibility {
    private var elements: [UInt32: AXUIElement] = [:]
    var adapter: WindowOverviewController.Adapter {
        .init(permitted: { AXIsProcessTrusted() }, open: { try await self.open() },
              snapshot: { self.snapshot() }, highlight: { try self.highlight($0) },
              confirm: { try await self.confirm($0) }, cancel: { self.cancel() })
    }
    private func open() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: WindowOverviewAction.bundleIdentifier) else {
            throw WindowOverviewFailure("未找到 macOS 系统窗口总览。")
        }
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: options)
    }
    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    private func snapshot() -> WindowOverviewSnapshot {
        elements = [:]
        var targets: [WindowOverviewTarget] = [], visible = false, visited = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        func visit(_ element: AXUIElement, inOverview: Bool, depth: Int) {
            guard depth <= 9, visited < 512, ProcessInfo.processInfo.systemUptime < deadline else { return }
            visited += 1
            let identifier = value(element, kAXIdentifierAttribute) as? String ?? ""
            if identifier.hasPrefix("mc.spaces") { return }
            let inside = inOverview || identifier == "mc" || identifier == "mc.display"
            if inside { visible = true }
            if inside, value(element, kAXRoleAttribute) as? String == kAXButtonRole, let rect = frame(element) {
                let raw = value(element, "wid")
                let number = (raw as? NSNumber)?.uint32Value ?? (raw as? String).flatMap(UInt32.init)
                if let id = number {
                    let target = WindowOverviewTarget(id: id, frame: rect)
                    if target.isValid { targets.append(target); elements[id] = element }
                }
            }
            for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child, inOverview: inside, depth: depth + 1) }
        }
        for bundle in ["com.apple.dock", "com.apple.WindowManager"] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { continue }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.05)
            visit(root, inOverview: false, depth: 0)
            if visible, !targets.isEmpty { break }
        }
        return .init(visible: visible, targets: targets)
    }
    private func highlight(_ target: WindowOverviewTarget) throws {
        let current = snapshot()
        guard current.visible, current.targets.filter({ $0.id == target.id }).count == 1,
              let actual = current.targets.first(where: { $0.id == target.id }),
              let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                  mouseCursorPosition: CGPoint(x: actual.frame.midX, y: actual.frame.midY), mouseButton: .left) else {
            throw WindowOverviewFailure("当前窗口已不在总览中，没有移动选择位置。")
        }
        event.flags = []; event.post(tap: .cghidEventTap)
    }
    private func confirm(_ id: UInt32) async throws {
        let current = snapshot()
        guard current.visible, current.targets.filter({ $0.id == id }).count == 1, let element = elements[id] else {
            throw WindowOverviewFailure("所选缩略窗口已改变，没有执行确认。")
        }
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success,
              (actions as? [String])?.contains(kAXPressAction) == true,
              AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            throw WindowOverviewFailure("系统没有接受这个窗口的确认操作。")
        }
        for _ in 0..<20 {
            try Task.checkCancellation()
            if !snapshot().visible, frontWindowID() == id { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw WindowOverviewFailure("已请求打开窗口，但尚未确认它已切到前台。")
    }
    private func frontWindowID() -> UInt32? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.first { entry in
            (entry[kCGWindowLayer as String] as? Int) == 0 && (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0
        }.flatMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }
    private func cancel() {
        guard snapshot().visible, AXIsProcessTrusted() else { return }
        for pressed in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: pressed)
            event?.flags = []; event?.post(tap: .cghidEventTap)
        }
    }
}

private struct WindowOverviewFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
