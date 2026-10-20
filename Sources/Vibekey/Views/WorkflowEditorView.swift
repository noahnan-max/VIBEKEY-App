import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibekeyCore

struct WorkflowEditorView: View {
    @ObservedObject var store: WorkflowStore
    @ObservedObject var device: DeviceStore
    var triggerID: String? = nil
    var detailed = false
    var radialEnabled = false
    var radialTriggerID = "key.1"
    var radialUsesHold = false
    @State private var scopeError: String?

    var body: some View {
        Group {
            if triggerID != nil && !detailed { quickBody }
            else { advancedBody }
        }.font(VIFLOWTheme.body).foregroundColor(VIFLOWTheme.ink)
            .onAppear { selectExistingBinding() }
            .onChange(of: triggerID) { _ in scopeError = nil; selectExistingBinding() }
            .onDisappear { store.flushAutomaticSave() }
    }

    private var quickBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Toggle("启用自定义配置", isOn: $store.enabled).toggleStyle(.switch)
                    .disabled(!device.connected).accessibilityIdentifier("vibekey.workflows.enabled")
                Spacer(minLength: 0)
                Text(store.enabled ? "已启用" : "当前使用基础配置").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
            }
            if let pause = triggerPauseMessage {
                Label(pause, systemImage: "pause.circle").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("vibekey.workflows.trigger-paused")
            }
            if let selected = selectedBinding {
                if matchingBindings.count > 1 {
                    Picker("应用范围", selection: selectedScope) {
                        ForEach(matchingBindings) { Text(scopeTitle($0)).tag(Optional($0.id)) }
                    }.accessibilityIdentifier("vibekey.workflows.scope")
                }
                quickEditor(selected)
                HStack(spacing: 10) {
                    Text(store.automaticSaveMessage)
                        .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    Spacer(minLength: 0)
                    if store.automaticSaveError != nil, configurationError == nil {
                        Button("重试") { store.flushAutomaticSave() }.disabled(store.running)
                            .accessibilityIdentifier("vibekey.workflows.retry")
                    }
                }
            } else { emptyEditor }
            if let error = scopeError ?? store.error ?? (selectedBinding?.validationError == nil ? configurationError : nil) {
                Label(error, systemImage: "exclamationmark.circle").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.errorInk)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("vibekey.workflows.error")
            }
        }
    }
    private func quickEditor(_ selected: WorkflowBinding) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if selected.steps.isEmpty { Text("选择一个要执行的动作。").foregroundColor(VIFLOWTheme.secondary) }
            ForEach(Array(selected.steps.enumerated()), id: \.element.id) { index, step in
                StepEditor(step: quickStep(selected, step), ordinal: index + 1,
                    canMoveUp: index > 0, canMoveDown: index + 1 < selected.steps.count,
                    moveUp: { moveQuickStep(selected, step, by: -1) }, moveDown: { moveQuickStep(selected, step, by: 1) },
                    remove: { var copy = binding(for: selected).wrappedValue; copy.steps.removeAll { $0.id == step.id }; binding(for: selected).wrappedValue = copy },
                    simple: selected.steps.count == 1)
                if index + 1 < selected.steps.count { Divider() }
            }
            DisclosureGroup("更多设置") {
                VStack(alignment: .leading, spacing: 14) {
                    Button("添加一个动作") {
                        var copy = binding(for: selected).wrappedValue; copy.steps.append(WorkflowStep(kind: .shortcut)); binding(for: selected).wrappedValue = copy
                    }.disabled(selected.steps.count >= WorkflowValidation.maximumStepCount).accessibilityIdentifier("vibekey.workflows.add-step")
                    TextField("动作名称", text: binding(for: selected).name).viflowInput().accessibilityIdentifier("vibekey.workflows.name")
                    Button("为某个应用单独设置…", action: addBinding).accessibilityIdentifier("vibekey.workflows.add")
                    Button("恢复VIBEKEY基础配置") {
                        var copy = binding(for: selected).wrappedValue; copy.steps = [WorkflowStep(kind: .passthrough, argument: "")]; binding(for: selected).wrappedValue = copy
                    }.accessibilityIdentifier("vibekey.workflows.restore-original")
                }.padding(.top, 12)
            }.font(VIFLOWTheme.caption)
        }.viflowPanel(padding: 18).disabled(store.running).id(selected.id)
    }
    private func quickStep(_ bindingValue: WorkflowBinding, _ step: WorkflowStep) -> Binding<WorkflowStep> {
        Binding(get: { AU05ActionDefaults.displayed(binding(for: bindingValue).wrappedValue.steps.first { $0.id == step.id } ?? step, triggerID: bindingValue.triggerID) }, set: { value in
            var copy = binding(for: bindingValue).wrappedValue
            guard let index = copy.steps.firstIndex(where: { $0.id == step.id }) else { return }
            copy.steps[index] = value; binding(for: bindingValue).wrappedValue = copy
        })
    }
    private func moveQuickStep(_ selected: WorkflowBinding, _ step: WorkflowStep, by delta: Int) {
        var copy = binding(for: selected).wrappedValue
        guard let index = copy.steps.firstIndex(where: { $0.id == step.id }), copy.steps.indices.contains(index + delta) else { return }
        copy.steps.swapAt(index, index + delta); binding(for: selected).wrappedValue = copy
    }

    private var advancedBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(triggerID == nil ? "按键与工作流" : "宏与工作流").font(VIFLOWTheme.subheading)
                    Text(triggerID == nil ? "选择工作流，编辑它的动作。" : "为这个位置组合动作，或为不同应用分别设置。")
                        .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                }
                Spacer(minLength: 8)
                Text(store.automaticSaveMessage).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                if triggerID == nil || !matchingBindings.isEmpty {
                    Button(action: addBinding) { Label(addTitle, systemImage: "plus") }
                        .disabled(store.running || store.bindings.count >= WorkflowValidation.maximumBindingCount)
                        .accessibilityIdentifier("vibekey.workflows.add")
                }
                if store.automaticSaveError != nil, configurationError == nil {
                    Button("重试") { store.flushAutomaticSave() }.disabled(store.running)
                        .accessibilityIdentifier("vibekey.workflows.retry")
                }
            }
            HStack(spacing: 14) {
                Toggle("启用 Mac 工作流", isOn: $store.enabled).toggleStyle(.switch)
                    .disabled(!device.connected).accessibilityIdentifier("vibekey.workflows.enabled")
                Text(triggerStatus).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let pause = triggerPauseMessage {
                Label(pause, systemImage: "pause.circle").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("vibekey.workflows.trigger-paused")
            }
            if triggerID != nil {
                if let selected = selectedBinding {
                    Picker("应用配置", selection: selectedScope) {
                        ForEach(matchingBindings) { Text(scopeTitle($0)).tag(Optional($0.id)) }
                    }
                    .accessibilityIdentifier("vibekey.workflows.scope")
                    editor(selected)
                } else { emptyEditor }
            } else {
                Divider()
                HStack(alignment: .top, spacing: 20) {
                    workflowList.frame(width: 180)
                    if let selected = selectedBinding { editor(selected) }
                    else { emptyEditor }
                }.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if store.running {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在执行工作流").font(VIFLOWTheme.caption)
                    Spacer()
                    Button("取消执行") { store.cancel() }.accessibilityIdentifier("vibekey.workflows.cancel")
                }
            }
            if let error = scopeError ?? store.error ?? configurationError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.errorInk)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("vibekey.workflows.error")
            }
        }
        .font(VIFLOWTheme.body).foregroundColor(VIFLOWTheme.ink)
    }

    private var workflowList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("工作流").font(VIFLOWTheme.subheading)
                Spacer()
                Text("\(store.bindings.count)").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary).monospacedDigit()
            }.padding(.horizontal, 8)
            if store.bindings.isEmpty {
                Text("暂无工作流").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    .padding(.horizontal, 8).padding(.top, 8)
            } else {
                VStack(spacing: 5) {
                    ForEach(store.bindings) { binding in
                        Button { store.selectedID = binding.id } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(binding.name.isEmpty ? "未命名工作流" : binding.name)
                                .font(VIFLOWTheme.font(13, weight: .semibold)).lineLimit(1)
                            Text(triggerTitle(binding.triggerID) + " · " + (binding.applicationBundleID.isEmpty ? "全局" : "指定应用"))
                                .font(VIFLOWTheme.caption).foregroundColor(store.selectedID == binding.id ? VIFLOWTheme.filledInk : VIFLOWTheme.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .foregroundColor(store.selectedID == binding.id ? VIFLOWTheme.filledInk : VIFLOWTheme.ink)
                        .background(store.selectedID == binding.id ? VIFLOWTheme.filled : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                        .accessibilityIdentifier("vibekey.workflows.binding.\(binding.id.uuidString)")
                    }
                }
                .accessibilityIdentifier("vibekey.workflows.list")
            }
        }
    }

    private var emptyEditor: some View {
        VStack(alignment: .center, spacing: 15) {
            Image(systemName: "command.square").font(.system(size: 38, weight: .light)).foregroundColor(VIFLOWTheme.secondary)
            Text(triggerID != nil ? "这个位置还没有按键动作" : store.bindings.isEmpty ? "一个按键，一组动作。" : "选择一个工作流")
                .font(VIFLOWTheme.font(18, weight: .semibold))
            Text(triggerID != nil ? "选择要执行的动作。" : store.bindings.isEmpty ? "添加工作流后，设置触发动作、应用范围和执行步骤。" : "左侧选择后即可编辑触发动作和步骤。")
                .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
            if triggerID != nil || store.bindings.isEmpty {
                Button(triggerID != nil ? "添加此按键工作流" : "新增工作流", action: addBinding)
                    .buttonStyle(VIFLOWPrimaryButtonStyle()).disabled(store.running || store.bindings.count >= WorkflowValidation.maximumBindingCount)
                    .accessibilityIdentifier("vibekey.workflows.add-for-trigger")
            }
        }
        .frame(maxWidth: .infinity, minHeight: triggerID == nil ? 320 : 200)
    }

    private var matchingBindings: [WorkflowBinding] { store.bindings.filter { triggerID == nil || $0.triggerID == triggerID } }
    private var selectedBinding: WorkflowBinding? {
        if let selected = matchingBindings.first(where: { $0.id == store.selectedID }) { return selected }
        return triggerID == nil ? nil : matchingBindings.first(where: { $0.applicationBundleID.isEmpty }) ?? matchingBindings.first
    }
    private var selectedScope: Binding<UUID?> {
        Binding(get: { selectedBinding?.id }, set: { id in
            guard let id, matchingBindings.contains(where: { $0.id == id }) else { return }
            store.selectedID = id
        })
    }
    private var addTitle: String {
        guard triggerID != nil else { return "新增" }
        return matchingBindings.contains(where: { $0.applicationBundleID.isEmpty }) ? "添加应用配置" : "添加全局配置"
    }
    private func selectExistingBinding() {
        guard triggerID != nil, !matchingBindings.contains(where: { $0.id == store.selectedID }) else { return }
        store.selectedID = (matchingBindings.first { $0.applicationBundleID.isEmpty } ?? matchingBindings.first)?.id
    }
    private func scopeTitle(_ binding: WorkflowBinding) -> String {
        let scope = binding.applicationBundleID.isEmpty ? "全局" : binding.applicationBundleID.split(separator: ".").last.map(String.init) ?? binding.applicationBundleID
        return scope + " · " + (binding.name.isEmpty ? "未命名" : binding.name)
    }
    private func addBinding() {
        guard !store.running, store.bindings.count < WorkflowValidation.maximumBindingCount else { return }
        guard let triggerID else { store.add(); return }
        var bundleID = "", name = triggerTitle(triggerID)
        if matchingBindings.contains(where: { $0.applicationBundleID.isEmpty }) {
            let panel = NSOpenPanel()
            panel.title = "为这个按键选择应用"; panel.canChooseFiles = true; panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.applicationBundle]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard let identifier = Bundle(url: url)?.bundleIdentifier else { scopeError = "这个应用没有可用的标识。"; return }
            if let existing = matchingBindings.first(where: { $0.applicationBundleID.caseInsensitiveCompare(identifier) == .orderedSame }) {
                store.selectedID = existing.id; scopeError = nil; return
            }
            bundleID = identifier; name = url.deletingPathExtension().lastPathComponent
        }
        let added = WorkflowBinding(name: name, triggerID: triggerID, applicationBundleID: bundleID,
                                    steps: [WorkflowStep(kind: .passthrough, argument: "")])
        store.bindings.append(added); store.selectedID = added.id; scopeError = nil
    }
    private func editor(_ selected: WorkflowBinding) -> some View {
        BindingEditor(binding: binding(for: selected), running: store.running, triggerLocked: triggerID != nil, triggerPaused: triggerPauseMessage != nil,
                      deviceShortcutFallback: detailed,
                      test: { if let current = store.bindings.first(where: { $0.id == selected.id }) { store.run(current) } },
                      remove: { store.remove(selected.id) })
            .id(selected.id)
    }
    private var triggerPauseMessage: String? {
        let current = selectedBinding?.triggerID ?? triggerID
        if current == radialTriggerID, radialEnabled, !radialUsesHold {
            return "此键已设为单击打开轮盘；可在快捷轮盘页自定义触发按键。"
        }
        return nil
    }
    private var triggerStatus: String {
        if !device.connected { return "未连接，仍可编辑。" }
        return store.enabled ? "所有已配置按键按应用范围生效。" : "未启用；使用设备快捷键。"
    }
    private var configurationError: String? {
        do { try WorkflowValidation.validate(store.bindings); return nil } catch { return error.localizedDescription }
    }
    private func triggerTitle(_ id: String) -> String { HardwareTrigger.available.first { $0.id == id }?.title ?? "未绑定" }
    private func binding(for fallback: WorkflowBinding) -> Binding<WorkflowBinding> {
        Binding(get: { store.bindings.first { $0.id == fallback.id } ?? fallback }, set: { value in
            guard let current = store.bindings.firstIndex(where: { $0.id == fallback.id }) else { return }
            store.bindings[current] = value
        })
    }
}

private struct BindingEditor: View {
    @Binding var binding: WorkflowBinding
    var running: Bool
    var triggerLocked = false
    var triggerPaused = false
    var deviceShortcutFallback = false
    let test: () -> Void
    let remove: () -> Void
    @State private var contextError: String?
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
                bindingFields
                Divider()
                HStack {
                    Text("执行步骤").font(VIFLOWTheme.subheading)
                    Text(showDeviceFallback ? "未配置" : "\(binding.steps.count) 步").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    Spacer()
                    Button {
                        if showDeviceFallback { binding.steps = [] }
                        binding.steps.append(WorkflowStep(kind: .delay, seconds: 0.25))
                    } label: { Label("添加步骤", systemImage: "plus") }
                        .controlSize(.small).disabled(binding.steps.count >= WorkflowValidation.maximumStepCount)
                        .accessibilityIdentifier("vibekey.workflows.add-step")
                }
                if showDeviceFallback {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("尚未设置 Mac 工作流，当前使用“快捷键”中保存的设备设置。")
                            .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("vibekey.workflows.device-fallback")
                        ActionPresetButton { preset in binding.steps = [preset.makeStep()] }
                    }
                } else if binding.steps.isEmpty {
                    Text("添加第一个动作。步骤会从上到下依次执行。")
                        .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary).padding(.vertical, 16)
                }
                if !showDeviceFallback { VStack(spacing: 16) {
                    ForEach(Array(binding.steps.enumerated()), id: \.element.id) { index, step in
                        StepEditor(step: stepBinding(for: step), ordinal: index + 1,
                                   canMoveUp: index > 0, canMoveDown: index < binding.steps.count - 1,
                                   moveUp: { moveStep(step.id, by: -1) }, moveDown: { moveStep(step.id, by: 1) },
                                   remove: { binding.steps.removeAll { $0.id == step.id } })
                        if index < binding.steps.count - 1 { Divider() }
                    }
                } }
                Divider()
                HStack(spacing: 12) {
                    Button(action: test) { Label("手动试运行", systemImage: "play.fill") }
                        .buttonStyle(VIFLOWPrimaryButtonStyle()).disabled(binding.validationError != nil || usesOnlyDeviceMapping)
                        .accessibilityIdentifier("vibekey.workflows.test")
                    Spacer(minLength: 0)
                    Button("删除工作流", role: .destructive) { confirmingDelete = true }
                        .accessibilityIdentifier("vibekey.workflows.remove")
                }
                Text(usesOnlyDeviceMapping ? (deviceShortcutFallback ? "当前使用设备快捷键。" : "当前使用VIBEKEY基础配置。") : triggerPaused ? "按键触发暂停；可手动试运行这组步骤。" : "调整后自动保存；启用开关控制按键生效。")
                    .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                if let message = contextError ?? binding.validationError {
                    Text(message).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.errorInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        .disabled(running).viflowPanel(padding: 20)
        .alert("删除这个工作流？", isPresented: $confirmingDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive, action: remove)
        } message: { Text("“\(binding.name)”的电脑端配置将从本机删除。") }
        .onChange(of: binding.applicationBundleID) { _ in contextError = nil }
    }

    private var usesOnlyDeviceMapping: Bool { !binding.steps.isEmpty && binding.steps.allSatisfy { $0.kind == .passthrough } }
    private var showDeviceFallback: Bool { deviceShortcutFallback && usesOnlyDeviceMapping }

    private var bindingFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                field("工作流名称") {
                    TextField("名称", text: $binding.name).viflowInput().accessibilityIdentifier("vibekey.workflows.name")
                }
                if !triggerLocked { field("触发动作") {
                    Picker("触发动作", selection: $binding.triggerID) {
                        if !HardwareTrigger.available.contains(where: { $0.id == binding.triggerID }) {
                            Text("未绑定").tag(binding.triggerID)
                        }
                        ForEach(HardwareTrigger.available) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden().frame(maxWidth: .infinity).padding(.vertical, 7)
                    .accessibilityIdentifier("vibekey.workflows.trigger")
                } }
            }
            if triggerLocked {
                DisclosureGroup("应用范围") { contextFields.padding(.top, 8) }
                    .font(VIFLOWTheme.caption)
            } else { contextFields }
        }
    }

    private var contextFields: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("应用范围").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    Spacer()
                    if !binding.applicationBundleID.isEmpty {
                        Button("设为全局") { binding.applicationBundleID = "" }.buttonStyle(.borderless).font(VIFLOWTheme.caption)
                    }
                    Button("选择应用…") { chooseContext() }.buttonStyle(.borderless).font(VIFLOWTheme.caption)
                        .accessibilityIdentifier("vibekey.workflows.choose-context")
                }
                TextField("留空表示全局；例如 com.apple.Safari", text: $binding.applicationBundleID)
                    .viflowInput().accessibilityIdentifier("vibekey.workflows.context")
                Text(binding.applicationBundleID.isEmpty ? "每个按键保留一份全局配置；额外场景可选择应用。" : "该应用在前台时，优先使用此配置。")
                    .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
            }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func stepBinding(for fallback: WorkflowStep) -> Binding<WorkflowStep> {
        Binding(get: { AU05ActionDefaults.displayed(binding.steps.first { $0.id == fallback.id } ?? fallback, triggerID: binding.triggerID) }, set: { value in
            guard let current = binding.steps.firstIndex(where: { $0.id == fallback.id }) else { return }
            binding.steps[current] = value
        })
    }
    private func moveStep(_ id: UUID, by distance: Int) {
        guard let current = binding.steps.firstIndex(where: { $0.id == id }), binding.steps.indices.contains(current + distance) else { return }
        var steps = binding.steps
        steps.swapAt(current, current + distance)
        binding.steps = steps
    }
    private func chooseContext() {
        let panel = NSOpenPanel()
        panel.title = "选择前台应用"; panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let identifier = Bundle(url: url)?.bundleIdentifier else { contextError = "这个应用没有可用的 bundle ID。"; return }
        binding.applicationBundleID = identifier
    }
}

struct StepEditor: View {
    @Binding var step: WorkflowStep
    let ordinal: Int
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void
    var radialAction = false
    var simple = false
    @State private var delayText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if simple {
                Picker("执行动作", selection: actionSelection) {
                    ForEach(ActionKind.allCases.filter { $0 != .passthrough }) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("vibekey.action.kind")
            } else { HStack(spacing: 10) {
                Text(String(format: "%02d", ordinal)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(VIFLOWTheme.secondary).frame(width: 24, alignment: .leading)
                Picker("动作类型", selection: actionSelection) { ForEach(ActionKind.allCases.filter{$0 != .passthrough}) { Text($0.title).tag($0) } }
                    .labelsHidden().frame(maxWidth: .infinity)
                HStack(spacing: 5) {
                    stepButton("上移", symbol: "chevron.up", action: moveUp).disabled(!canMoveUp)
                    stepButton("下移", symbol: "chevron.down", action: moveDown).disabled(!canMoveDown)
                    Button(role: .destructive, action: remove) { Image(systemName: "trash").frame(width: 20, height: 24) }
                        .buttonStyle(.borderless).help("移除第 \(ordinal) 步").accessibilityLabel("移除第 \(ordinal) 步")
                }
            } }
            ActionPresetButton { preset in step = preset.makeStep(id: step.id) }
                .padding(.leading, simple ? 0 : 34)
            stepFields.padding(.leading, simple ? 0 : 34)
            if let message = step.validationError, !([ActionKind.openApp, .openURL, .runShortcut, .inputSource].contains(step.kind) && step.argument.isEmpty) {
                Text(message).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.errorInk)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, simple ? 0 : 34)
            }
        }
        .accessibilityIdentifier("vibekey.workflows.step.\(step.id.uuidString)")
        .onAppear { delayText = String(step.seconds) }
        .onChange(of: step.kind) { kind in
            if kind == .delay { delayText = String(step.seconds) }
            else if !step.seconds.isFinite { step.seconds = 0.25 }
        }
    }

    private var actionSelection: Binding<ActionKind> {
        Binding(get: { step.kind }, set: { kind in
            guard kind != step.kind else { return }
            step.kind = kind; step.argument = ""
        })
    }

    @MainActor @ViewBuilder private var stepFields: some View {
        switch step.kind {
        case .passthrough:
            VStack(alignment: .leading, spacing: 7) {
                if !simple { Text(step.argument.isEmpty ? "沿用当前设备映射" : step.argument).font(VIFLOWTheme.subheading)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Text("使用VIBEKEY基础映射。")
                    .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .shortcut:
            VStack(alignment: .leading, spacing: 10) {
                ShortcutRecorder(value:RecordedShortcut(keyCode:step.keyCode,modifiers:step.modifiers),identifier:"shortcut.recorder."+step.id.uuidString) { value in
                    guard step.kind == .shortcut else {return}
                    step.keyCode=value.keyCode;step.modifiers=value.modifiers
                }.frame(maxWidth:.infinity).frame(height:34)
                DisclosureGroup("手动设置") {
                Picker("主键", selection: $step.keyCode) {
                    if !ShortcutKeyCatalog.entries.contains(where: { $0.0 == step.keyCode }) { Text("键码 \(step.keyCode)（现有值）").tag(step.keyCode) }
                    ForEach(ShortcutKeyCatalog.entries, id: \.0) { key in Text(key.1).tag(key.0) }
                }
                HStack(spacing: 6) {
                    Text("修饰键").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    flag("⌘", name: "Command", mask: 0x00100000)
                    flag("⌥", name: "Option", mask: 0x00080000)
                    flag("⌃", name: "Control", mask: 0x00040000)
                    flag("⇧", name: "Shift", mask: 0x00020000)
                    flag("fn", name: "Function", mask: 0x00800000)
                }
                }.font(VIFLOWTheme.caption)
            }
        case .scrollUp, .scrollDown:
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("每转一格滚动").font(VIFLOWTheme.body)
                    Spacer()
                    Stepper("\(step.scrollLines) 行", value: $step.scrollLines, in: AU05ActionDefaults.scrollRange)
                        .fixedSize().accessibilityIdentifier("vibekey.scroll.lines")
                }
                Slider(value: Binding(get: { Double(step.scrollLines) }, set: { step.scrollLines = Int($0.rounded()) }), in: 1...50, step: 1)
                    .accessibilityLabel("每格滚动行数").accessibilityIdentifier("vibekey.scroll.amount")
                Text("范围1–50行，实际距离由当前应用决定；轮盘内仍逐项选择。")
                    .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
            }
        case .openApp:
            VStack(alignment: .leading, spacing: 8) {
                if simple {
                    HStack { Text(applicationName).foregroundColor(VIFLOWTheme.secondary); Spacer(); Button("选择应用…") { chooseApp() } }
                    DisclosureGroup("手动输入应用地址") { TextField("应用 ID 或 .app 路径", text: $step.argument).viflowInput().padding(.top, 8) }.font(VIFLOWTheme.caption)
                } else {
                    TextField("应用 ID 或 .app 路径", text: $step.argument).viflowInput()
                    Button("选择应用…") { chooseApp() }.buttonStyle(.borderless).font(VIFLOWTheme.caption)
                }
            }
        case .openURL:
            TextField("https://example.com", text: $step.argument).viflowInput()
        case .runShortcut:
            VStack(alignment: .leading, spacing: 7) {
                TextField("系统「快捷指令」中的准确名称", text: $step.argument).viflowInput()
                Text("按名称运行已存在的系统快捷指令。")
                    .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
            }
        case .delay:
            HStack(spacing: 10) {
                TextField("0.25", text: $delayText).viflowInput().frame(width: 90)
                    .accessibilityLabel("等待秒数")
                    .onChange(of: delayText) { value in
                        guard step.kind == .delay else { return }
                        step.seconds = Double(value.replacingOccurrences(of: ",", with: ".")) ?? .nan
                    }
                Text("秒 · 最多 30 秒").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
            }
        case .volumeUp, .volumeDown, .toggleMute:
            Text("控制电脑当前默认输出设备，操作后回读确认。")
                .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .inputSource:
            VStack(alignment:.leading,spacing:8) {
                Picker("本地输入法",selection:$step.argument) {
                    if !InputSourceCatalog.available.contains(where:{$0.id == step.argument}) {Text("选择已启用的输入法").tag(step.argument)}
                    ForEach(InputSourceCatalog.available) {source in Text(source.name).tag(source.id)}
                }.accessibilityIdentifier("vibekey.workflows.inputSource")
                Text("切换 macOS 中已启用的输入法，随后可追加它的快捷键。")
                    .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
            }
        }
    }
    private func stepButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 20, height: 24) }
            .buttonStyle(.borderless).help("\(title)第 \(ordinal) 步").accessibilityLabel("\(title)第 \(ordinal) 步")
    }
    private var applicationName: String {
        let url = step.argument.hasPrefix("/") ? URL(fileURLWithPath: step.argument) : NSWorkspace.shared.urlForApplication(withBundleIdentifier: step.argument)
        return url?.deletingPathExtension().lastPathComponent ?? (step.argument.isEmpty ? "尚未选择应用" : "应用未安装或尚未选择")
    }
    private func flag(_ title: String, name: String, mask: UInt64) -> some View {
        Toggle(title, isOn: Binding(get: { step.modifiers & mask != 0 }, set: { value in
            if value { step.modifiers |= mask } else { step.modifiers &= ~mask }
        }))
        .toggleStyle(.button).controlSize(.small).help(name).accessibilityLabel(name)
    }
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "选择要打开的应用"; panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.applicationBundle]
        if panel.runModal() == .OK, let url = panel.url {
            step.argument = radialAction ? (Bundle(url:url)?.bundleIdentifier ?? "") : url.path
        }
    }
}
