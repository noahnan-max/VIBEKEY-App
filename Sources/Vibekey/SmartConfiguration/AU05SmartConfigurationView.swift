import AppKit
import SwiftUI
import VibekeyCore

@MainActor struct AU05SmartConfigurationView: View {
    @ObservedObject var store: AU05SmartConfigurationStore
    @ObservedObject private var model: SmartConfigurationStore
    @ObservedObject private var device: DeviceStore
    @State private var apiExpanded: Bool
    @State private var restoring = false
    init(store: AU05SmartConfigurationStore) {
        self.store = store; model = store.model; device = store.device
        _apiExpanded = State(initialValue: store.prepared == nil && !store.model.configurationSaved)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName:"sparkles").font(VIFLOWTheme.font(23)).foregroundColor(VIFLOWTheme.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("智能配置 · AU05").font(VIFLOWTheme.title)
                    Text(store.ready ? "AU05 已就绪 · 六个按键与旋钮位置" : "请连接并唤醒 AU05").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    Text("先预览，再备份与应用；以完整读回结果确认完成。").foregroundColor(VIFLOWTheme.secondary)
                }; Spacer(); if store.isBusy || model.isBusy { ProgressView().controlSize(.small) }
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment:.leading, spacing:18) {
                    SmartModelSettingsView(model:model, apiExpanded:$apiExpanded, busy:store.isBusy)
                    composer
                    VStack(alignment:.leading, spacing:8) {
                        Label(store.message, systemImage:store.verification == nil ? "info.circle" : "checkmark.shield")
                        if let error = store.error { Text(error).foregroundColor(VIFLOWTheme.errorInk).accessibilityIdentifier("vibekey.smart.au05.error") }
                        if let result = store.verification { Text(result).foregroundColor(VIFLOWTheme.accent).accessibilityIdentifier("vibekey.smart.au05.verified") }
                    }.font(VIFLOWTheme.caption).fixedSize(horizontal:false, vertical:true)
                    if let p = store.prepared { preview(p) }
                    if let backup = store.lastBackup {
                        VStack(alignment:.leading, spacing:10) {
                            Label("AU05 原配置备份", systemImage:"externaldrive.badge.checkmark").font(VIFLOWTheme.subheading)
                            Text(backup.lastPathComponent).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                            HStack {
                                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
                                Button("恢复此备份…") { restoring = true }.disabled(store.isBusy || model.isBusy || !store.ready).accessibilityIdentifier("vibekey.smart.au05.restore")
                            }
                        }.viflowPanel()
                    }
                }.padding(20).frame(maxWidth:.infinity, alignment:.leading)
            }
        }.frame(minWidth:720, minHeight:620).font(VIFLOWTheme.body).foregroundColor(VIFLOWTheme.ink)
            .background(VIFLOWTheme.canvas).tint(VIFLOWTheme.accent).buttonStyle(VIFLOWSecondaryButtonStyle())
            .onChange(of:store.request) { _ in store.invalidate() }
            .onChange(of:model.settings) { _ in store.cancel(); store.invalidate() }
            .onChange(of:device.connectionID) { _ in store.cancel(); store.invalidate() }
            .onDisappear { store.cancel() }
            .alert("恢复 AU05 原配置？", isPresented:$restoring) {
                Button("取消", role:.cancel) {}
                Button("备份当前配置并恢复", role:.destructive) { store.restore() }
            } message: { Text("恢复所示备份中的六个设备快捷键、灯光、全部 Mac 宏及相关开关。先备份当前配置，固件不一致时停止；请确认当前连接的是要恢复的 AU05。") }
            .accessibilityIdentifier("vibekey.smart.au05.window")
    }
    private var composer: some View {
        VStack(alignment:.leading, spacing:12) {
            Text("希望怎样配置？").font(VIFLOWTheme.subheading)
            ZStack(alignment:.topLeading) {
                TextEditor(text:$store.request).font(VIFLOWTheme.body).frame(minHeight:85,maxHeight:130).padding(5).accessibilityLabel("AU05 配置需求").accessibilityIdentifier("vibekey.smart.au05.request")
                if store.request.isEmpty { Text("例如：上键复制，中键先复制、等0.3秒再粘贴；灯光全亮，亮度8。").foregroundColor(VIFLOWTheme.secondary).padding(10).allowsHitTesting(false) }
            }.overlay(RoundedRectangle(cornerRadius:6).stroke(VIFLOWTheme.controlBorder)).disabled(store.isBusy)
            Text("快捷键与普通灯光保存到设备；智能配置生成全局 Mac 宏，在所有应用中生效，退出 VIBEKEY 后暂停。灯光支持全灭、全亮、工作模式及0–20亮度。")
                .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary).fixedSize(horizontal:false, vertical:true)
            Text("仅发送本次需求、六位置的当前快捷键、宏占用计数和已知灯光。已有宏原文、本机备份与设备标识不发送。")
                .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary).fixedSize(horizontal:false, vertical:true)
            HStack {
                if store.isBusy && !store.applying { Button("停止生成") { store.cancel() } }
                Spacer()
                Button("生成配置方案") { apiExpanded = false; store.generate() }.buttonStyle(VIFLOWPrimaryButtonStyle())
                    .disabled(!store.ready || store.isBusy || model.isBusy || store.recoveryRequired || store.request.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers:.command).accessibilityIdentifier("vibekey.smart.au05.generate")
            }
        }.viflowPanel()
    }
    private func preview(_ p: AU05SmartPrepared) -> some View {
        VStack(alignment:.leading, spacing:12) {
            Label("AU05 配置预览 · 尚未写入", systemImage:"list.bullet.rectangle").font(VIFLOWTheme.subheading)
            Text(p.plan.summary).fixedSize(horizontal:false, vertical:true)
            if let q = p.plan.clarification { Text(q).foregroundColor(VIFLOWTheme.accent) }
            ForEach(Array(p.changes.enumerated()), id:\.offset) { _, line in Text("• " + line).fixedSize(horizontal:false, vertical:true) }
            ForEach(Array(p.plan.macros.enumerated()), id:\.offset) { _, macro in
                if !macro.remove {
                    DisclosureGroup("Mac 宏 · " + AU05SmartSnapshot.title(macro.trigger) + " · 查看具体步骤") {
                        ForEach(Array(macro.steps.enumerated()), id:\.offset) { index, step in Text("\(index + 1). " + AU05SmartModel.stepDescription(step)).font(VIFLOWTheme.caption).frame(maxWidth:.infinity, alignment:.leading) }
                    }
                }
            }
            if !p.acknowledgements.isEmpty { Toggle("我已核对上方原有宏及开关的变化，允许应用", isOn:$store.acknowledged).toggleStyle(.checkbox).accessibilityIdentifier("vibekey.smart.au05.acknowledge") }
            if p.hasChanges {
                HStack {
                    Text("先备份六个快捷键、完整灯光和 Mac 宏；备份失败或原配置变化则停止。").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    Spacer(minLength:10)
                    Button("备份并应用") { store.apply() }.buttonStyle(VIFLOWPrimaryButtonStyle()).disabled(!store.canApply).accessibilityIdentifier("vibekey.smart.au05.apply")
                }
            }
        }.viflowPanel().disabled(store.isBusy || model.isBusy)
    }
}
