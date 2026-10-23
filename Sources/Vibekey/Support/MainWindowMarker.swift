import AppKit
import OSLog
import SwiftUI

/// Identifies the main window so the menu bar can reopen it without creating another.
struct MainWindowMarker: NSViewRepresentable {
    var identifier = "vibekey.main"
    func makeNSView(context: Context) -> MarkerView {
        let view = MarkerView(); view.targetIdentifier = identifier; return view
    }
    func updateNSView(_ nsView: MarkerView, context: Context) { nsView.targetIdentifier = identifier }

    final class MarkerView: NSView {
        var targetIdentifier = "vibekey.main"
        // This view only observes its window; it must never become a mouse target.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = NSUserInterfaceItemIdentifier(targetIdentifier)
        }
    }
}

/// Finite, app-local click diagnostics. No keyboard events or user text are read.
@MainActor final class HardwareInteractionDiagnostics {
    private let logger = Logger(subsystem: "io.github.noahnan-max.VIBEKEY", category: "Windowing")
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var appMouseDownCount = 0
    private var mouseDownCount = 0
    private var lastMouseRegion = "none"
    private var lastMouseModifiers: UInt = 0
    private var lastWindowEvent = "none"

    func start(changed: @escaping () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            appMouseDownCount += 1
            guard event.window?.identifier?.rawValue == "vibekey.main" else { changed(); return event }
            mouseDownCount += 1
            lastMouseRegion = event.locationInWindow.x < VIFLOWTheme.sidebarWidth ? "sidebar" : "content"
            lastMouseModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
            changed()
            return event
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let owner = self else { return }
                let eventName = notification.name.rawValue
                Task { @MainActor in
                    owner.lastWindowEvent = eventName
                    owner.logger.info("Window lifecycle: \(eventName, privacy: .public)")
                    changed()
                }
            })
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    var snapshot: [String: Any] {
        let window = NSApp.windows.first { $0.identifier?.rawValue == "vibekey.main" }
        return ["appActive": NSApp.isActive, "appRunning": NSApp.isRunning,
                "appClass": String(describing: type(of: NSApp!)),
                "activationPolicy": NSApp.activationPolicy().rawValue,
                "appMouseDownCount": appMouseDownCount, "lastWindowEvent": lastWindowEvent,
                "hasModalWindow": NSApp.modalWindow != nil,
                "mainWindowPresent": window != nil, "mainWindowVisible": window?.isVisible ?? false,
                "mainWindowKey": window?.isKeyWindow ?? false,
                "mainWindowCanBecomeKey": window?.canBecomeKey ?? false,
                "mainWindowCanBecomeMain": window?.canBecomeMain ?? false,
                "mainWindowClass": window.map { String(describing: type(of: $0)) } ?? "none",
                "mainWindowNumber": window?.windowNumber ?? 0,
                "mainWindowStyle": window?.styleMask.rawValue ?? 0,
                "mainWindowCount": NSApp.windows.filter { $0.identifier?.rawValue == "vibekey.main" }.count,
                "keyWindowNumber": NSApp.keyWindow?.windowNumber ?? 0,
                "mainWindowIgnoresMouseEvents": window?.ignoresMouseEvents ?? false,
                "mainWindowOccluded": window.map { !$0.occlusionState.contains(.visible) } ?? true,
                "mainWindowLevel": window?.level.rawValue ?? 0,
                "mouseDownCount": mouseDownCount, "lastMouseRegion": lastMouseRegion,
                "lastMouseModifiers": lastMouseModifiers]
    }
}
