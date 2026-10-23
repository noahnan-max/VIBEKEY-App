import SwiftUI
import VibekeyCore

@MainActor struct SmartModelSettingsView: View {
    @ObservedObject var model: SmartConfigurationStore
    @Binding var apiExpanded: Bool
    var busy = false
    @State private var showStatus = false
    var body: some View {
        DisclosureGroup(isExpanded: $apiExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("接入方式", selection: $model.provider) {
                    Text("通用 API").tag(SmartModelProvider.openAICompatible)
                    Text("本机 Codex 登录").tag(SmartModelProvider.codexLogin)
                }.pickerStyle(.segmented).accessibilityIdentifier("vibekey.smart.provider")
                if model.provider == .openAICompatible {
                HStack {
                    Text("国内、海外云模型或本机模型，使用 OpenAI Chat Completions 兼容接口。")
                        .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    Spacer(minLength: 8)
                    Button("填入 DeepSeek") { model.useDeepSeek() }
                }
                Text("可填写完整的 /chat/completions 地址，或服务商的 API 根地址。")
                    .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                labeled("API 地址") { TextField("https://服务地址/v1", text: $model.baseURL).viflowInput().accessibilityIdentifier("vibekey.smart.api-url") }
                labeled("模型名称") { TextField("填写服务商提供的模型 ID", text: $model.model).viflowInput().accessibilityIdentifier("vibekey.smart.model") }
                labeled("API Key") {
                    SecureField(model.savedKey ? "已保存；填写新密钥可替换" : "本机无密钥服务可留空", text: $model.apiKeyInput)
                        .viflowInput().accessibilityIdentifier("vibekey.smart.api-key")
                }
                } else {
                    Text("复用这台 Mac 的 Codex / ChatGPT 登录，由官方 Codex CLI 调用。无需 API Key，VIBEKEY 不读取或保存 OAuth token。")
                        .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    labeled("Codex 模型") { TextField("留空使用 Codex 默认模型", text: $model.codexModel).viflowInput() }
                    Text("只生成配置方案：独立的只读调用，禁用命令执行、插件、MCP 和网页搜索；使用当前 Codex 账户的可用额度。")
                        .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("检测 Codex 登录") { showStatus = true; model.checkCodexLogin() }.accessibilityIdentifier("vibekey.smart.codex-login")
                }
                HStack(spacing: 10) {
                    Button("保存设置") { showStatus = true; model.saveSettings() }.accessibilityIdentifier("vibekey.smart.save-settings")
                    Button("测试连接") { showStatus = true; model.testConnection() }.accessibilityIdentifier("vibekey.smart.test-connection")
                    if model.provider == .openAICompatible && model.savedKey { Button("移除此端点密钥") { showStatus = true; model.deleteKey() } }
                    Spacer(minLength: 8)
                    if model.modelReady { Label("模型调用已验证", systemImage: "checkmark.circle").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary) }
                    else if model.configurationSaved { Text("设置已保存，待验证调用").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary) }
                }
                if model.provider == .openAICompatible {
                    Text("密钥仅存于 macOS 钥匙串，并按 API 地址隔离。远程接口需要 HTTPS，本机回环接口允许 HTTP。")
                        .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("首次读取密钥可能需要系统授权；成功读取后，本次运行在内存中复用。钥匙串密码仅在 macOS 系统窗口输入。")
                        .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if showStatus {
                    HStack(alignment: .top, spacing: 8) {
                        if model.isBusy { ProgressView().controlSize(.small) }
                        Text(model.message).fixedSize(horizontal: false, vertical: true)
                    }.font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    if let error = model.error { Text(error).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.errorInk).fixedSize(horizontal: false, vertical: true) }
                }
            }.padding(.top, 12).disabled(model.isBusy)
            if model.isBusy { Button("停止模型操作") { model.cancel() } }
        } label: {
            Label(model.provider == .codexLogin ? "本机 Codex 登录" : "模型 API", systemImage: "network").font(VIFLOWTheme.subheading)
        }
        .viflowPanel()
        .disabled(busy)
        .onChange(of: model.baseURL) { _ in showStatus = false; model.endpointEdited() }
        .onChange(of: model.provider) { _ in showStatus = false; model.endpointEdited() }
        .onChange(of: model.codexModel) { _ in showStatus = false; model.settingsEdited() }
        .onChange(of: model.model) { _ in showStatus = false; model.settingsEdited() }
    }
    private func labeled<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).frame(width: 76, alignment: .leading).foregroundColor(VIFLOWTheme.secondary)
            content().frame(maxWidth: .infinity)
        }
    }
}
