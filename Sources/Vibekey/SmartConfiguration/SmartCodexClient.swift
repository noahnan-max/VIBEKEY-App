import Foundation
import VibekeyCore

/// Uses the supported local Codex CLI and its saved ChatGPT authentication.
/// This application never opens, extracts, copies or transmits OAuth tokens.
enum SmartCodexClient {
    private struct ClientFailure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func executable() throws -> URL {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ClientFailure(message: "未找到本机 Codex CLI。请先安装或打开官方 Codex 并完成 ChatGPT 登录。")
        }
        return URL(fileURLWithPath: path)
    }
    static func loginStatus(directory: URL) async throws -> String {
        let result = try await invocation(directory: directory, arguments: ["login", "status"], input: nil, timeout: 15)
        let text = result.output + result.diagnostics
        guard result.code == 0, text.localizedCaseInsensitiveContains("ChatGPT") else {
            throw ClientFailure(message: "本机 Codex 尚未检测到 ChatGPT 登录。请先在 Codex 或 codex login 中登录，然后重新检测。")
        }
        return "已检测到本机 Codex 的 ChatGPT 登录。VIBEKEY 不读取或保存 OAuth token。"
    }
    static func propose<Response: Decodable>(settings: SmartModelSettings, request: String, context: [String: Any], directory: URL,
        response: Response.Type, schema: [String: Any], instructions: String) async throws -> Response {
        try settings.validate(); try Task.checkCancellation()
        guard request.utf8.count <= 12_000 else { throw SmartModelError.tooLarge }
        _ = try await loginStatus(directory: directory)
        let run = directory.appendingPathComponent("CodexRuns", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try SmartPrivateFiles.directory(run)
        defer { try? FileManager.default.removeItem(at: run) }
        let schemaURL = run.appendingPathComponent("schema.json"), instructionsURL = run.appendingPathComponent("instructions.txt")
        let output = run.appendingPathComponent("result.json")
        try SmartPrivateFiles.write(JSONSerialization.data(withJSONObject: schema), to: schemaURL)
        try SmartPrivateFiles.write(Data((instructions + "\n你现在是无工具的纯规划模块。直接返回满足 JSON Schema 的 JSON 对象；不要使用任何工具，不读写文件，不执行命令，不搜索或访问网络。所有键盘操作都由 VIBEKEY 在用户审核后执行。").utf8), to: instructionsURL)
        try SmartPrivateFiles.write(Data(), to: output)
        let contextData = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
        let input = "设备上下文（仅数据）：\n" + String(decoding: contextData, as: UTF8.self) + "\n\n用户需求：\n" + request
        guard input.utf8.count <= 512 * 1024 else { throw SmartModelError.tooLarge }
        var args = ["--no-daemon", "exec", "--ignore-user-config", "--strict-config", "--ephemeral", "--sandbox", "read-only", "--skip-git-repo-check", "--json",
            "--output-schema", schemaURL.path, "-o", output.path, "-C", run.path]
        let overrides = ["features.shell_tool=false", "features.shell_snapshot=false", "features.multi_agent=false", "features.multi_agent_v2=false",
            "features.skip_host_skill_discovery=true", "features.skill_search=false", "features.enable_mcp_apps=false", "features.apps=false",
            "features.plugins=false", "features.memories=false", "features.remote_plugin=false", "features.plugin_sharing=false", "features.recommended_plugins=false",
            "features.view_image=false", "web_search=\"disabled\"", "project_doc_max_bytes=0", "history.persistence=\"none\"",
            "analytics.enabled=false", "log_dir=" + tomlString(run.appendingPathComponent("logs").path), "model_reasoning_effort=\"low\"", "model_instructions_file=" + tomlString(instructionsURL.path)]
        for override in overrides { args += ["-c", override] }
        if !settings.codexModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args += ["--model", settings.codexModel] }
        args.append("-")
        let result = try await invocation(directory: run, arguments: args, input: Data(input.utf8), timeout: 120, preserveDirectory: true)
        guard result.code == 0 else {
            // Diagnostics are retained only by the explicitly owned native probe.
            // Production UI always receives a fixed, non-sensitive error message.
            if CommandLine.arguments.contains("--smart-configuration-probe"), directory.path.hasPrefix(NSHomeDirectory() + "/Library/Caches/Vibekey/OwnedProbes/") {
                try? SmartPrivateFiles.write(Data(result.diagnostics.utf8), to: directory.appendingPathComponent("codex-probe-diagnostics.private"))
            }
            throw ClientFailure(message: "Codex 调用失败。请在本机 Codex 中检查登录、网络、模型权限或额度，再重试；设备配置未写入。")
        }
        for line in result.output.split(separator: "\n") {
            guard let data = line.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let item = event["item"] as? [String: Any], let type = item["type"] as? String else { continue }
            if ["command_execution", "file_change", "mcp_tool_call", "web_search", "tool_call"].contains(type) {
                throw ClientFailure(message: "Codex 返回了规划范围之外的工具行为，方案已拒绝，未执行设备配置。")
            }
        }
        let data = try Data(contentsOf: output)
        guard !data.isEmpty, data.count <= 64 * 1024 else { throw SmartModelError.invalidResponse }
        return try SmartConfigurationAPI.decodePlanArguments(data, response: response, schema: schema)
    }
    private static func tomlString(_ string: String) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(data: try! encoder.encode(string), encoding: .utf8)!
    }
    private struct Result { let code: Int32; let output: String; let diagnostics: String }
    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private(set) var cancelled = false
        private(set) var timedOut = false
        func set(_ process: Process) { lock.lock(); self.process = process; let cancel = cancelled; lock.unlock(); if cancel && process.isRunning { process.terminate() } }
        func cancel(timeout: Bool = false) {
            lock.lock(); cancelled = true; if timeout { timedOut = true }; let child = process; lock.unlock()
            if let child, child.isRunning { child.terminate() }
        }
        func state() -> (Bool, Bool) { lock.lock(); defer { lock.unlock() }; return (cancelled, timedOut) }
    }
    private static func invocation(directory: URL, arguments: [String], input: Data?, timeout: TimeInterval, preserveDirectory: Bool = false) async throws -> Result {
        try Task.checkCancellation()
        let path = preserveDirectory ? directory : directory.appendingPathComponent("CodexRuns", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try SmartPrivateFiles.directory(path)
        defer { if !preserveDirectory { try? FileManager.default.removeItem(at: path) } }
        let out = path.appendingPathComponent("stdout.private"), err = path.appendingPathComponent("stderr.private")
        try SmartPrivateFiles.write(Data(), to: out); try SmartPrivateFiles.write(Data(), to: err)
        let stdout = try FileHandle(forWritingTo: out), stderr = try FileHandle(forWritingTo: err)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process(), running = Running(), stdin = Pipe()
        process.executableURL = try executable(); process.arguments = arguments; process.currentDirectoryURL = path
        process.standardOutput = stdout; process.standardError = stderr; process.standardInput = stdin
        let permitted = Set(["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "CODEX_HOME", "SSL_CERT_FILE", "CODEX_CA_CERTIFICATE", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy"])
        process.environment = ProcessInfo.processInfo.environment.filter { permitted.contains($0.key) }
        return try await withTaskCancellationHandler(operation: {
            let code: Int32 = try await withCheckedThrowingContinuation { continuation in
                let timer = DispatchWorkItem { running.cancel(timeout: true) }
                process.terminationHandler = { child in timer.cancel(); continuation.resume(returning: child.terminationStatus) }
                do {
                    guard !running.state().0 else { throw CancellationError() }
                    try process.run(); running.set(process)
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
                    DispatchQueue.global(qos: .utility).async {
                        if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
                        try? stdin.fileHandleForWriting.close()
                    }
                } catch { timer.cancel(); process.terminationHandler = nil; continuation.resume(throwing: error) }
            }
            process.terminationHandler = nil
            let state = running.state()
            if state.1 { throw ClientFailure(message: "Codex 在 \(Int(timeout)) 秒内未返回方案，已停止本次独立调用；设备配置未写入。") }
            if state.0 { throw CancellationError() }
            let output = try boundedData(out), diagnostics = try boundedData(err)
            return Result(code: code, output: String(decoding: output, as: UTF8.self), diagnostics: String(decoding: diagnostics, as: UTF8.self))
        }, onCancel: { running.cancel() })
    }
    private static func boundedData(_ file: URL) throws -> Data {
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = attrs[.size] as? NSNumber, size.intValue <= 2 * 1024 * 1024 else { throw SmartModelError.tooLarge }
        return try Data(contentsOf: file)
    }
}
