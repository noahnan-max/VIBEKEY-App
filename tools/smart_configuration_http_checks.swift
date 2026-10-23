import Foundation
import VibekeyCore

@main @MainActor enum SmartConfigurationHTTPChecks {
    static let fixtureKey = "fixture-only-value-not-a-secret"
    static func main() async {
        var results: [[String: Any]] = []
        do {
            guard let base = ProcessInfo.processInfo.environment["VIBEKEY_SMART_FIXTURE_BASE"],
                  let url = URLComponents(string: base), url.scheme == "http", url.host == "127.0.0.1",
                  url.port != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty else { throw Failure("Loopback fixture base required") }
            func propose(_ scenario: String, model: String = "fixture-generic", route: String = "/v1",
                         context: [String: Any] = ["fixture": true]) async throws -> AU05SmartPlan {
                try await SmartConfigurationAPI.propose(settings: .init(baseURL: base + route, model: model),
                    apiKey: fixtureKey, request: "HTTP_CASE:" + scenario, context: context,
                    response: AU05SmartPlan.self, schema: AU05SmartModel.schema, instructions: AU05SmartModel.instructions)
            }
            func record(_ name: String, _ value: Bool) throws {
                results.append(["case": name, "result": value ? "PASS" : "FAIL"])
                guard value else { throw Failure(name) }
            }
            let generic = try await propose("valid")
            try record("generic-forced-tool", generic.keys.first?.trigger == "key.0" && generic.keys.first?.keyCode == 90)
            let deepSeek = try await propose("valid", model: "deepseek-fixture")
            try record("deepseek-auto-tool", deepSeek.keys.first?.keyCode == 90)
            let cases = ["unknown-root", "unknown-macro", "unknown-step", "unknown-light", "unknown-key",
                         "wrong-tool", "missing-tool", "two-tools", "invalid-arguments", "boolean-keycode",
                         "thinking-conflict", "schema-error", "unauthorized", "opaque-error", "oversized-response"]
            for scenario in cases {
                var rejected = false
                do { _ = try await propose(scenario) }
                catch {
                    let description = error.localizedDescription
                    rejected = !description.contains(fixtureKey) && !description.contains("DO_NOT_SURFACE_REQUEST")
                    if scenario == "thinking-conflict" { rejected = rejected && description.contains("思考") }
                    if scenario == "schema-error" { rejected = rejected && description.contains("参数格式") }
                    if scenario == "oversized-response" {
                        if case SmartModelError.tooLarge = error {} else { rejected = false }
                    }
                }
                try record(scenario, rejected)
            }
            var redirected = false
            do { _ = try await propose("valid", route: "/redirect") }
            catch { if case SmartModelError.redirects = error { redirected = true } }
            try record("redirect-rejected", redirected)
            var oversized = false
            do { _ = try await propose("oversized-request", context: ["value": String(repeating: "x", count: 530 * 1024)]) }
            catch { if case SmartModelError.tooLarge = error { oversized = true } }
            try record("oversized-request-before-network", oversized)
            let cancelled = Task { try await propose("cancelled-before-send") }
            cancelled.cancel()
            var cancellation = false
            do { _ = try await cancelled.value } catch is CancellationError { cancellation = true }
            try record("cancelled-before-network", cancellation)
            for address in ["http://example.invalid/v1", "https://user:secret@example.invalid/v1",
                            "https://example.invalid/v1?key=secret", "file:///tmp/model"] {
                var invalid = false
                do { _ = try SmartModelSettings(baseURL: address, model: "fixture").endpoint() }
                catch { invalid = true }
                try record("invalid-endpoint-\(results.count)", invalid)
            }
            emit(["result": "PASS", "checks": results, "cloudRequests": 0, "keychainAccesses": 0,
                  "physicalDeviceWrites": 0, "hostInputPosted": 0])
        } catch {
            emit(["result": "FAIL", "checks": results, "failure": String(reflecting: type(of: error)),
                  "cloudRequests": 0, "keychainAccesses": 0, "physicalDeviceWrites": 0])
            exit(1)
        }
    }
    struct Failure: Error { let name: String; init(_ name: String) { self.name = name } }
    static func emit(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
    }
}
