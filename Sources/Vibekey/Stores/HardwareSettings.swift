import AppKit
import ApplicationServices
import Combine

@MainActor final class HardwareSettings:ObservableObject {
    @Published private(set) var accessibilityGranted=AXIsProcessTrusted()
    @Published var suspended=false
    @Published var appearanceMode:AppAppearance {
        didSet {
            guard appearanceMode != oldValue else {return}
            preferences?.set(appearanceMode.rawValue,forKey:AppAppearance.preferenceKey)
            applyAppearance()
        }
    }
    private let preferences:UserDefaults?
    let loginItem: LoginItemStore
    private var observer:NSObjectProtocol?
    init(preferences:UserDefaults? = .standard) {
        self.preferences=preferences
        loginItem = LoginItemStore(live: preferences != nil)
        appearanceMode=preferences?.string(forKey:AppAppearance.preferenceKey).flatMap(AppAppearance.init(rawValue:)) ?? .system
        observer=NotificationCenter.default.addObserver(forName:NSApplication.didBecomeActiveNotification,object:nil,queue:.main) {[weak self] _ in
            guard let owner=self else {return};Task {@MainActor in owner.refresh()}
        }
    }
    func applyAppearance() {NSApplication.shared.appearance=appearanceMode.nativeAppearance}
    func refresh() {accessibilityGranted=AXIsProcessTrusted();loginItem.refresh()}
    func openAccessibilitySettings() {
        if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {NSWorkspace.shared.open(url)}
    }
    var version:String {(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"}
}
