import SwiftUI
import VibekeyCore

@MainActor struct RadialMenuSettingsView: View {
    @ObservedObject var store: RadialMenuStore
    @ObservedObject var controller: RadialMenuController
    @State private var deleting: UUID?
    @State private var libraryTarget: LibraryTarget?
    private enum LibraryTarget: Identifiable {
        case append, replace(UUID)
        var id: String { switch self { case .append: return "append"; case .replace(let id): return id.uuidString } }
        var isAppend: Bool { if case .append = self { return true }; return false }
    }
    private var busy: Bool { controller.isPresented || controller.executing }
    private var selected: RadialMenuItem? { store.draft.items.first { $0.id == store.selectedID } }
    private var selectedIndex: Int? { store.draft.items.firstIndex { $0.id == store.selectedID } }
    private var pageIndex: Int { (selectedIndex ?? 0) / 8 }
    private var pageCount: Int { max(1, store.draft.pageCount) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Toggle("启用轮盘", isOn: $store.draft.enabled).toggleStyle(.switch).disabled(busy || !store.isReady).accessibilityIdentifier("radial.enabled")
                Spacer()
                Button("预览") { controller.showPreview() }
                    .disabled(controller.executing || (controller.isPresented && !controller.previewMode) || store.draft.items.isEmpty).accessibilityIdentifier("radial.preview")
                    .help("预览不执行动作，点击轮盘中央或空白处关闭。")
                Text(store.automaticSaveMessage).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                if store.error != nil, store.isReady, (try? RadialMenuValidation.validate(store.draft)) != nil {
                    Button("重试") { store.flushAutomaticSave() }.disabled(busy).accessibilityIdentifier("radial.retry")
                }
            }
            openingOptions
            HStack {
                Text(!store.isReady ? "配置待检查 · 已暂停" : store.configuration.enabled ? "已启用" : "未启用 · 可以先预览")
                Spacer()
                Text("\(store.draft.items.count) 个选项").help("最多64个选项，每页8个")
            }.font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
            HStack(alignment: .top, spacing: 16) {
                visualSelector.frame(width: 300)
                Divider()
                ScrollView {
                    if let item = selected { itemEditor(item).padding(.trailing, 8) }
                    else { Text("点击轮盘空位，添加功能。").foregroundColor(VIFLOWTheme.secondary).padding(24) }
                }
            }.frame(maxHeight: .infinity)
            if let text = store.error ?? controller.message {
                Text(text).font(VIFLOWTheme.caption).foregroundColor(store.error == nil ? VIFLOWTheme.secondary : VIFLOWTheme.errorInk)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("radial.message")
            }
        }.background(VIFLOWTheme.canvas)
            .onDisappear { store.flushAutomaticSave(); if controller.previewMode { controller.cancel() } }
            .sheet(item: $libraryTarget) { target in
                ActionLibraryView(maximumSelection: target.isAppend ? max(1, 64 - store.draft.items.count) : 1,
                    selectionVerb: target.isAppend ? "添加" : "选用") { presets in
                    apply(presets, to: target); libraryTarget = nil
                }
            }
            .confirmationDialog("删除这个轮盘项目？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除", role: .destructive) { if let id = deleting { store.remove(id) }; deleting = nil }
                Button("取消", role: .cancel) { deleting = nil }
            } message: { Text("此选项将从轮盘中移除并自动保存。") }
    }
    private func itemEditor(_ item: RadialMenuItem) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("选项名称").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
            TextField("例如：复制", text: itemBinding(item).name).viflowInput().disabled(busy).accessibilityIdentifier("radial.name")
            Button { libraryTarget = .replace(item.id) } label: { Label("从动作库替换此选项…", systemImage: "square.grid.2x2") }
                .disabled(busy).accessibilityIdentifier("radial.library.replace")
            if WindowOverviewAction.matches(item.steps) {
                Button { controller.testWindowOverview() } label: { Label("试运行窗口总览", systemImage: "play") }
                    .disabled(busy).accessibilityIdentifier("radial.window-overview.test")
                Text("打开系统总览后，转动旋钮选择窗口，按下旋钮确认；也可在底部提示条上滚动并点确认。\(store.draft.activation.cancelTriggerID == "key.0" ? "上键" : "下键")或 Esc 取消。")
                    .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary).fixedSize(horizontal:false,vertical:true)
            }
            ForEach(Array(item.steps.enumerated()), id: \.element.id) { index, step in
                StepEditor(step: stepBinding(item, step), ordinal: index + 1, canMoveUp: index > 0, canMoveDown: index + 1 < item.steps.count,
                    moveUp: { moveStep(item, step, by: -1) }, moveDown: { moveStep(item, step, by: 1) },
                    remove: { var copy = item; copy.steps.removeAll { $0.id == step.id }; replace(copy) }, radialAction: true, simple: item.steps.count == 1)
                    .disabled(busy)
                if index + 1 < item.steps.count { Divider() }
            }
            if item.steps.isEmpty { Button("选择动作") { var copy = item; copy.steps = [WorkflowStep(kind: .shortcut)]; replace(copy) }.disabled(busy) }
            DisclosureGroup("更多设置") {
                VStack(alignment: .leading, spacing: 12) {
                    Button("再添加一个动作") { var copy = item; copy.steps.append(WorkflowStep(kind: .shortcut)); replace(copy) }
                        .disabled(busy || item.steps.count >= WorkflowValidation.maximumStepCount).accessibilityIdentifier("radial.addStep")
                    HStack {
                        Button("向前移一格") { store.move(item.id, by: -1) }.disabled(busy || store.draft.items.first?.id == item.id)
                        Button("向后移一格") { store.move(item.id, by: 1) }.disabled(busy || store.draft.items.last?.id == item.id)
                    }
                    Button("删除这个选项…", role: .destructive) { deleting = item.id }.disabled(busy)
                }.padding(.top, 10)
            }.font(VIFLOWTheme.caption)
        }
    }
    private var openingOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            RadialTriggerPicker(store: store, disabled: busy)
            Text(store.draft.activation.instruction).foregroundColor(VIFLOWTheme.secondary)
        }.font(VIFLOWTheme.caption)
    }
    private var visualSelector: some View {
        let displayedPage = pageIndex, items = store.draft.page(pageIndex)
        return VStack(spacing: 14) {
            RadialScrollSelection(enabled: !busy, onRotate: rotateSelection) {
            RadialWheelDiagram(items: items, selectedSlot: selectedIndex.map { $0 % 8 }, diameter: 284,
                centerHeading: "点击编辑", centerTitle: selected?.name ?? "添加动作", centerCaption: pageCount > 1 ? "\(pageIndex + 1) / \(pageCount)" : "",
                centerSymbol: "pencil", canAdd: store.draft.items.count < 64, identifierPrefix: "radial.editor.slot.",
                onSelect: { slot in
                    guard !busy, pageIndex == displayedPage, items.indices.contains(slot), store.draft.items.contains(where: { $0.id == items[slot].id }) else { return }
                    store.selectedID = items[slot].id
                }, onAdd: {
                    guard !busy, pageIndex == displayedPage, store.draft.page(pageIndex).map(\.id) == items.map(\.id) else { return }
                    store.add()
                }).disabled(busy)
            }.frame(width: 284, height: 284).padding(.vertical, 10)
                .help("在圆盘上滚动选择，转完本页自动翻页，反向滚动返回。")
            if pageCount > 1 {
                HStack(spacing: 20) {
                    Button { selectPage(pageIndex - 1) } label: { Image(systemName: "chevron.left") }.disabled(busy || pageIndex == 0).accessibilityLabel("上一页轮盘").accessibilityIdentifier("radial.previousPage")
                    Text("第 \(pageIndex + 1) / \(pageCount) 页").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    Button { selectPage(pageIndex + 1) } label: { Image(systemName: "chevron.right") }.disabled(busy || pageIndex + 1 >= pageCount).accessibilityLabel("下一页轮盘").accessibilityIdentifier("radial.nextPage")
                }
            }
            Button { libraryTarget = .append } label: { Label("从动作库添加…", systemImage: "square.grid.2x2") }
                .disabled(busy || store.draft.items.count >= 64).accessibilityIdentifier("radial.library.add")
            Button { store.add() } label: { Label("添加自定义选项", systemImage: "plus") }.disabled(busy || store.draft.items.count >= 64).accessibilityIdentifier("radial.add")
            Spacer(minLength: 0)
        }
    }
    private func selectPage(_ page:Int) {
        guard let item = store.draft.page(page).first else {return}
        store.selectedID = item.id
    }
    private func apply(_ presets: [ActionPreset], to target: LibraryTarget) {
        guard !busy, !presets.isEmpty else { return }
        switch target {
        case .append:
            guard presets.count <= RadialMenuValidation.maximumItems - store.draft.items.count else { return }
            let added = presets.map { RadialMenuItem(name: $0.title, steps: [$0.makeStep()]) }
            store.draft.items.append(contentsOf: added); store.selectedID = added.first?.id
        case .replace(let id):
            guard var item = store.draft.items.first(where: { $0.id == id }), let preset = presets.first else { return }
            item.name = preset.title; item.steps = [preset.makeStep()]; replace(item)
        }
    }
    private func rotateSelection(_ delta: Int) {
        guard !busy, !store.draft.items.isEmpty else { return }
        let count = store.draft.items.count
        let current = selectedIndex ?? 0
        store.selectedID = store.draft.items[(current + delta % count + count) % count].id
    }
    private func replace(_ item:RadialMenuItem) {
        guard let index = store.draft.items.firstIndex(where:{$0.id == item.id}) else {return}
        store.draft.items[index] = item
    }
    private func itemBinding(_ item:RadialMenuItem)->Binding<RadialMenuItem> {
        Binding(get:{store.draft.items.first{$0.id == item.id} ?? item},set:{replace($0)})
    }
    private func stepBinding(_ item:RadialMenuItem,_ step:WorkflowStep)->Binding<WorkflowStep> {
        Binding(get:{store.draft.items.first{$0.id == item.id}?.steps.first{$0.id == step.id} ?? step},set:{value in
            guard var copy = store.draft.items.first(where:{$0.id == item.id}),let index = copy.steps.firstIndex(where:{$0.id == step.id}) else {return}
            copy.steps[index] = value;replace(copy)
        })
    }
    private func moveStep(_ item:RadialMenuItem,_ step:WorkflowStep,by delta:Int) {
        guard var copy = store.draft.items.first(where:{$0.id == item.id}),let index = copy.steps.firstIndex(where:{$0.id == step.id}),copy.steps.indices.contains(index+delta) else {return}
        copy.steps.swapAt(index,index+delta);replace(copy)
    }
}

struct RadialTriggerPicker: View {
    @ObservedObject var store: RadialMenuStore
    var disabled = false
    var body: some View {
        Picker("轮盘触发", selection: Binding(get: { store.draft.activation }, set: { value in
            guard value != store.draft.activation else { return }
            store.draft.activation = value; store.draft.schemaVersion = 3
        })) {
            ForEach([RadialActivation.topPress, .topHold, .middlePress, .middleHold, .bottomPress, .bottomHold, .knobPress, .knobHold], id: \.self) { Text($0.title).tag($0) }
        }.frame(maxWidth: 330).disabled(disabled || !store.isReady).accessibilityIdentifier("radial.activation")
    }
}
