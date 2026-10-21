import AppKit
import Combine
import Carbon

@MainActor final class AppLaunchState: ObservableObject {
    @Published private(set) var background: Bool
    private(set) var launchedAtLogin = false
    init(arguments: [String] = CommandLine.arguments) {
        background = arguments.contains("--background") || arguments.contains("--ui-probe")
    }
    func readLoginEvent(_ event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent) {
        launchedAtLogin = Self.isLoginEvent(event)
        background = background || launchedAtLogin
    }
    static func isLoginEvent(_ event: NSAppleEventDescriptor?) -> Bool {
        event?.eventID == kAEOpenApplication
            && [keyAELaunchedAsLogInItem, keyAELaunchedAsServiceItem].contains(event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue ?? 0)
    }
    func revealMainWindow() { background = false }
    func hideInitialWindows() {
        guard background else { return }
        NSApp.windows.filter { $0.identifier?.rawValue == "vibekey.main" }.forEach { $0.orderOut(nil) }
    }
}
