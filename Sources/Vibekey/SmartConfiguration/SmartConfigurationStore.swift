import Combine
import Foundation
import VibekeyCore

/// Shared model access for the AU05 planner. Device writes belong to its
/// separate preview/backup/transaction Store.
@MainActor final class SmartConfigurationStore: ObservableObject {
    @Published var baseURL = "https://api.deepseek.com"
    @Published var model = "deepseek-flash"
    @Published var provider: SmartModelProvider = .openAICompatible
    @Published var codexModel = ""
    @Published var apiKeyInput = "" { didSet { if apiKeyInput != oldValue { modelReady = false } } }
    @Published private(set) var configurationSaved = false
    @Published private(set) var savedKey = false
    @Published private(set) var modelReady = false
    @Published private(set) var isBusy = false
    @Published private(set) var message = "选择模型服务，保存设置后测试连接；生成方案仍需单独确认应用。"
    @Published private(set) var error: String?
    private let directory: URL
    private let preferences: SmartConfigurationPreferences
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(directory: URL) {
        self.directory = directory
        preferences = SmartConfigurationPreferences(directory: directory)
        do {
            let value = try preferences.load()
            baseURL = value.baseURL; model = value.model
            provider = value.provider; codexModel = value.codexModel
            configurationSaved = preferences.hasSavedSettings
            savedKey = preferences.hasKey(value)
        } catch { self.error = error.localizedDescription }
    }
    var settings: SmartModelSettings {
        SmartModelSettings(baseURL: baseURL, model: model, provider: provider, codexModel: codexModel)
    }
    func settingsEdited() { savedKey = preferences.hasKey(settings); modelReady = false }
    func endpointEdited() { apiKeyInput = ""; settingsEdited() }
    func useDeepSeek() {
        apiKeyInput = ""; provider = .openAICompatible
        baseURL = "https://api.deepseek.com"; model = "deepseek-flash"; settingsEdited()
    }
    func checkCodexLogin() {
        run("正在检测本机 Codex 登录…") {
            self.message = try await SmartCodexClient.loginStatus(directory: self.directory)
            self.modelReady = false
        }
    }
    func saveSettings() {
        let value = settings, newKey = apiKeyInput.isEmpty ? nil : apiKeyInput
        run("正在保存模型设置…") {
            try await self.preferences.save(value, newKey: newKey)
            self.apiKeyInput = ""; self.savedKey = self.preferences.hasKey(value)
            self.modelReady = false; self.configurationSaved = true
            self.message = value.provider == .codexLogin
                ? "已选择本机 Codex 登录；无需填写或复制 OAuth token。"
                : "模型设置已保存，密钥仅保存在本机钥匙串。"
        }
    }
    func deleteKey() {
        let value = settings
        run("正在移除此端点密钥…") {
            try await self.preferences.deleteKey(value)
            self.apiKeyInput = ""; self.savedKey = false; self.modelReady = false
            self.message = "已移除此端点保存的密钥。"
        }
    }
    func testConnection() {
        modelReady = false
        run("正在测试模型工具调用…") {
            let plan: AU05SmartPlan = try await self.propose(
                request: "这是接口连接测试。不要提出配置。返回 summary 为 API 连接成功，clarification 为 连接测试完成，keys 和 macros 都为空，lighting 为 null。",
                context: ["connection_test": true, "device_model": "AU05"],
                response: AU05SmartPlan.self, schema: AU05SmartModel.schema, instructions: AU05SmartModel.instructions)
            guard plan.keys.isEmpty, plan.macros.isEmpty, plan.lighting == nil else {
                self.modelReady = false; throw SmartModelError.invalidResponse
            }
            self.modelReady = true
            self.message = "模型连接和工具调用格式已验证；未读取或修改设备。"
        }
    }
    private func modelCredentials() async throws -> (SmartModelSettings, String) {
        let value = settings; try value.validate()
        if value.provider == .codexLogin { return (value, "") }
        let input = apiKeyInput
        return (value, input.isEmpty ? try await preferences.key(value) : input)
    }
    func propose<Response: Decodable>(request: String, context: [String: Any], response: Response.Type,
                                      schema: [String: Any], instructions: String) async throws -> Response {
        modelReady = false
        let (value, key) = try await modelCredentials()
        let plan: Response
        if value.provider == .codexLogin {
            plan = try await SmartCodexClient.propose(settings: value, request: request, context: context,
                directory: directory, response: response, schema: schema, instructions: instructions)
        } else {
            plan = try await SmartConfigurationAPI.propose(settings: value, apiKey: key, request: request,
                context: context, response: response, schema: schema, instructions: instructions)
        }
        try Task.checkCancellation()
        modelReady = true
        return plan
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; isBusy = false
    }
    private func run(_ status: String, _ action: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        let token = UUID(); generation = token; isBusy = true; error = nil; message = status
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.isBusy = false; self.task = nil } }
            do { try await action() }
            catch is CancellationError {
                if self.generation == token { self.modelReady = false; self.message = "已停止模型操作，设备配置未写入。" }
            } catch {
                guard self.generation == token else { return }
                self.modelReady = false; self.error = error.localizedDescription
                self.message = "模型操作未通过，设备配置未写入。"
            }
        }
    }
}
