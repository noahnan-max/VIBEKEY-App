import Foundation
import VibekeyCore

@main enum ActionCatalogChecks {
    static func main() throws {
        let presets = ActionCatalog.presets
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            guard value else { fatalError(message) }; checks += 1
        }
        check(Set(presets.map(\.id)).count == presets.count, "Duplicate preset IDs")
        check(ActionCategory.allCases.allSatisfy { category in presets.contains { $0.category == category } }, "Empty category")
        for preset in presets {
            let first = preset.makeStep(), second = preset.makeStep()
            check(first.id != second.id, "Repeated selection reuses step identity")
            try WorkflowValidation.validate([first, second])
            let stable = UUID()
            check(preset.makeStep(id: stable).id == stable, "Replacing a step changes editor identity")
            let binding = WorkflowBinding(name: preset.title, triggerID: "key.0", steps: [first])
            try WorkflowValidation.validate([binding])
            let document = RadialMenuDocument(schemaVersion: 3, items: [RadialMenuItem(name: preset.title, steps: [first])], activation: .topHold)
            let decoded = try RadialMenuCodec.decode(RadialMenuCodec.encode(document))
            check(decoded == document, "Preset cannot roundtrip through radial persistence")
        }
        let byID = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
        func shortcut(_ id: String, _ code: UInt16, _ flags: UInt64) {
            check(byID[id]?.step.kind == .shortcut && byID[id]?.step.keyCode == code && byID[id]?.step.modifiers == flags, "Wrong shortcut semantics: " + id)
        }
        shortcut("windows.previous-app", 48, 0x100000)
        shortcut("windows.next-window", 50, 0x100000)
        shortcut("browser.next-tab", 48, 0x40000)
        shortcut("browser.previous-tab", 48, 0x60000)
        shortcut("editing.plain-paste", 9, 0x1a0000)
        shortcut("browser.chrome-plain-paste", 9, 0x120000)
        shortcut("screenshots.clipboard", 21, 0x160000)
        check(byID["windows.next-window"]!.matches("窗口"), "Chinese search")
        check(byID["apps.com.google.Chrome"]!.matches("chrome"), "Case insensitive application search")
        check(byID["browser.next-tab"]!.matches("标签 浏览器"), "Multiword search")
        check(!byID["editing.copy"]!.matches("无此动作"), "Unknown search matches")
        let repeated = (0..<64).map { _ in RadialMenuItem(name: "复制", steps: [byID["editing.copy"]!.makeStep()]) }
        try RadialMenuValidation.validate(RadialMenuDocument(schemaVersion: 3, items: repeated))
        check(Set(repeated.flatMap(\.steps).map(\.id)).count == 64, "Batch insert reuses identities")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vibekey-catalog-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workflows.json")
        let original = WorkflowBinding(name: "existing", triggerID: "key.0", applicationBundleID: "com.apple.TextEdit", steps: [WorkflowStep(keyCode: 0)])
        var updated = original
        updated.steps[0] = byID["editing.copy"]!.makeStep(id: original.steps[0].id)
        try WorkflowPersistence.save([updated], to: url)
        let loaded = try WorkflowPersistence.load(from: url)
        check(loaded == [updated] && loaded[0].id == original.id && loaded[0].applicationBundleID == original.applicationBundleID, "Preset change loses scope or binding identity")
        print("{\"status\":\"PASS\",\"presets\":\(presets.count),\"categories\":\(ActionCategory.allCases.count),\"checks\":\(checks),\"hostActionsExecuted\":0}")
        if let index = CommandLine.arguments.firstIndex(of: "--markdown"), CommandLine.arguments.indices.contains(index + 1) {
            var lines = ["# VIBEKEY 快捷动作清单", "", "内置 \(presets.count) 项，按 \(ActionCategory.allCases.count) 类整理。轮盘与 AU05 电脑增强按键共用同一动作库；选用后自动保存有效配置，功能启用开关单独控制。输入法分类还会显示本机已启用的输入法。", "", "打开应用按本机安装状态提供；快捷键使用系统默认组合，改过系统快捷键时请重新录制。窗口、应用、标签页、桌面分别列出。", ""]
            for category in ActionCategory.allCases {
                lines += ["## " + category.title, "", "| 动作 | 快捷键 / 方式 | 适用范围 |", "|---|---|---|"]
                for preset in presets where preset.category == category {
                    lines.append("| \(preset.title) | \(preset.shortcutLabel ?? preset.step.kind.title) | \(preset.detail) |")
                }
                lines.append("")
            }
            lines += ["## 官方参考", "", "- [Apple：Mac 快捷键](\(ActionCatalog.apple))", "- [Apple：调度中心](\(ActionCatalog.missionControl))", "- [Apple：Safari 快捷键](\(ActionCatalog.safari))", "- [Google：Chrome 快捷键](\(ActionCatalog.chrome))", "", "查询记录：官方网页搜索2组（Mac窗口切换、Chrome快捷键）；阅读Apple、Safari、Chrome原文。agent-reach Exa未配置；OpenCLI Google查询1次，Browser Bridge未连接，改用公开网页工具。"]
            try (lines.joined(separator: "\n") + "\n").write(toFile: CommandLine.arguments[index + 1], atomically: true, encoding: .utf8)
        }
    }
}
