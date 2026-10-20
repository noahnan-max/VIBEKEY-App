import AppKit

@main @MainActor enum AppAppearanceChecks {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let original = NSApp.appearance
        let systemStyle = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        let domain = "io.github.noahnan-max.VIBEKEY.appearance-checks." + UUID().uuidString
        let preferences = UserDefaults(suiteName: domain)!
        defer {
            NSApp.appearance = original
            preferences.removePersistentDomain(forName: domain)
        }
        var checks: [String: Bool] = [:]
        let settings = HardwareSettings(preferences: preferences)
        checks["firstLaunchFollowsSystem"] = settings.appearanceMode == .system
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 380, height: 410), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        for mode in AppAppearance.allCases {
            settings.appearanceMode = mode
            settings.applyAppearance()
            checks[mode.rawValue + "Persisted"] = HardwareSettings(preferences: preferences).appearanceMode == mode
            if let expected = mode.nativeAppearance?.name {
                checks[mode.rawValue + "App"] = NSApp.appearance?.name == expected
                checks[mode.rawValue + "MainWindow"] = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected
                checks[mode.rawValue + "FloatingPanel"] = panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected
            } else {
                checks["systemClearsOverride"] = NSApp.appearance == nil
                checks["systemWindowInherits"] = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            }
        }
        settings.appearanceMode = .system
        checks["returnToSystem"] = NSApp.appearance == nil
        preferences.set("unknown-future-mode", forKey: AppAppearance.preferenceKey)
        checks["unknownModeFallsBackToSystem"] = HardwareSettings(preferences: preferences).appearanceMode == .system
        checks["nilPreferencesUseSystem"] = HardwareSettings(preferences: nil).appearanceMode == .system
        checks["systemPreferenceUnchanged"] = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == systemStyle
        let passed = checks.values.allSatisfy { $0 }
        let result: [String: Any] = ["status": passed ? "PASS" : "FAIL", "checks": checks, "checksPassed": checks.values.filter { $0 }.count,
            "hardwareStarted": false, "globalSystemThemeChanged": false, "realOSThemeToggle": "NOT_RUN"]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
        if !passed { exit(1) }
    }
}
