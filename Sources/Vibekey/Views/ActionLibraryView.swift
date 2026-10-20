import AppKit
import SwiftUI
import VibekeyCore

/// Browsing never changes configuration. Choosing an action edits the existing
/// model, which automatically persists valid values without executing a macro.
struct ActionPresetButton: View {
    var title = "从动作库选择…"
    var onboardShortcutsOnly = false
    let choose: (ActionPreset) -> Void
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: { Label(title, systemImage: "square.grid.2x2") }
            .accessibilityIdentifier("action-library.open")
            .sheet(isPresented: $presented) {
                ActionLibraryView(onboardShortcutsOnly: onboardShortcutsOnly) { values in
                    if let preset = values.first { choose(preset) }
                    presented = false
                }
            }
    }
}

@MainActor struct ActionLibraryView: View {
    var maximumSelection = 1
    var selectionVerb = "选用"
    var onboardShortcutsOnly = false
    let choose: ([ActionPreset]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var category = "recommended"
    @State private var query = ""
    @State private var items = ActionCatalog.presets
    @State private var unavailable = Set<String>()
    @State private var selected = Set<String>()

    private var availableItems: [ActionPreset] {
        onboardShortcutsOnly ? items.filter { $0.onboardShortcut != nil } : items
    }
    private var filtered: [ActionPreset] {
        availableItems.filter { preset in
            (category == "all" || (category == "recommended" && preset.recommended) || category == preset.category.rawValue)
                && preset.matches(query)
        }
    }
    private var selectedItems: [ActionPreset] { availableItems.filter { selected.contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("快捷动作库").font(VIFLOWTheme.title)
                    Text(onboardShortcutsOnly ? "选择常用快捷键，自动保存到 AU05。" : (maximumSelection > 1 ? "按分类挑选，可一次添加多个动作。" : "选择动作后自动填好并保存配置。"))
                        .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("action-library.cancel")
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(VIFLOWTheme.secondary)
                TextField("搜索动作、窗口、复制、Chrome…", text: $query)
                    .textFieldStyle(.plain).accessibilityIdentifier("action-library.search")
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("清除搜索") }
            }.padding(10).background(VIFLOWTheme.muted, in: RoundedRectangle(cornerRadius: 7))
            HStack(spacing: 0) {
                List(selection: $category) {
                    Label { Text("常用推荐") } icon: { Image(systemName: "star").foregroundColor(VIFLOWTheme.secondary) }.tag("recommended")
                    Label { Text("全部动作") } icon: { Image(systemName: "square.grid.2x2").foregroundColor(VIFLOWTheme.secondary) }.tag("all")
                    ForEach(ActionCategory.allCases.filter { value in availableItems.contains { $0.category == value } }) { value in
                        Label { Text(value.title) } icon: { Image(systemName: value.symbol).foregroundColor(VIFLOWTheme.secondary) }.tag(value.rawValue)
                    }
                }.listStyle(.sidebar).frame(width: 176).accessibilityIdentifier("action-library.categories")
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(filtered.count) 个动作").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                        Spacer()
                        if !query.isEmpty, category != "all" {
                            Button("搜索全部分类") { category = "all" }.font(VIFLOWTheme.caption)
                                .accessibilityIdentifier("action-library.search-all")
                        }
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if filtered.isEmpty {
                                Text("没有匹配的动作。可换个关键词，或搜索全部分类。")
                                    .font(VIFLOWTheme.body).foregroundColor(VIFLOWTheme.secondary).padding(.vertical, 35)
                            }
                            ForEach(filtered) { preset in
                                row(preset)
                                Divider()
                            }
                        }
                    }.accessibilityIdentifier("action-library.results")
                }.padding(.leading, 16).frame(maxWidth: .infinity)
            }
            HStack(spacing: 12) {
                Text(onboardShortcutsOnly ? "这里只显示可存入 AU05 的快捷键；打开应用、多步骤等 Mac 动作请在“宏与工作流”中选择。" : "选用后自动保存；应用专用动作请在对应应用中使用。")
                    .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if maximumSelection > 1 {
                    Text("\(selected.count) / \(maximumSelection)").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    Button("\(selectionVerb)选中的 \(selected.count) 项") { choose(selectedItems) }
                        .buttonStyle(VIFLOWPrimaryButtonStyle()).disabled(selected.isEmpty)
                        .accessibilityIdentifier("action-library.apply")
                }
            }
        }.padding(24).frame(width: 780, height: 590)
            .font(VIFLOWTheme.body).foregroundColor(VIFLOWTheme.ink).background(VIFLOWTheme.canvas)
            .tint(VIFLOWTheme.accent).buttonStyle(VIFLOWSecondaryButtonStyle())
            .onAppear(perform: loadLocalOptions)
            .onChange(of: query) { value in if !value.isEmpty, category == "recommended" { category = "all" } }
    }
    private func row(_ preset: ActionPreset) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: preset.category.symbol).frame(width: 22).foregroundColor(VIFLOWTheme.secondary).padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(preset.title).font(VIFLOWTheme.font(13, weight: .semibold))
                    Spacer(minLength: 5)
                    if let label = preset.shortcutLabel {
                        Text(label).font(.system(size: 12, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 3).background(VIFLOWTheme.muted, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(preset.detail).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary).fixedSize(horizontal: false, vertical: true)
                if unavailable.contains(preset.id) { Text("本机未找到此应用，可在动作编辑器中选择其他应用。 ").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary) }
            }
            if maximumSelection > 1 {
                Toggle("选择" + preset.title, isOn: Binding(get: { selected.contains(preset.id) }, set: { value in
                    if value { guard selected.count < maximumSelection else { return }; selected.insert(preset.id) }
                    else { selected.remove(preset.id) }
                })).labelsHidden().toggleStyle(.checkbox)
                    .disabled(unavailable.contains(preset.id) || (!selected.contains(preset.id) && selected.count >= maximumSelection))
                    .accessibilityIdentifier("action-library.select." + preset.id)
            } else {
                Button(selectionVerb) { choose([preset]) }.disabled(unavailable.contains(preset.id))
                    .accessibilityLabel(selectionVerb + preset.title).accessibilityIdentifier("action-library.select." + preset.id)
            }
        }.padding(.vertical, 13)
    }
    private func loadLocalOptions() {
        guard !onboardShortcutsOnly else { return }
        unavailable = Set(ActionCatalog.presets.filter { $0.step.kind == .openApp && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.step.argument) == nil }.map(\.id))
        items = ActionCatalog.presets + InputSourceCatalog.available.map { source in
            ActionPreset(id: "input." + source.id, title: "切换到" + source.name,
                detail: "直接切换本机已启用的输入法，不依赖循环次序。", category: .system,
                step: WorkflowStep(kind: .inputSource, argument: source.id))
        }
    }
}
