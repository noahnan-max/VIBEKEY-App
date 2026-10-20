# Agent integration / Agent 接入

Agent lighting is optional. Shortcuts, workflows and the radial menu work without Agent hooks. The source implements Codex and Claude Code event adapters; support in a particular installed Agent must be checked through real events.

## Hook bridge

The bridge uses the Python standard library. Python 3.11+ can also inspect TOML configuration with built-in `tomllib`. To print a proposed merge plan:

```sh
python3 script/agent_signal_bridge.py --plan
```

This command **prints a plan only**. It reads local configuration summaries and includes your local paths in its output; inspect it privately. It does not change hook configuration, install a service, change trust, or send anything to a server.

Review the proposed event groups in the context of your installed Agent. Merge additions into existing arrays while retaining current handlers, `notify` settings and unrelated fields. Follow the Agent's normal hook review/trust flow. Do not replace an entire configuration file with generated fragments or copy another person's trust data.

The runtime handler takes an event on standard input with an explicit source:

```sh
# The Agent supplies the JSON event on stdin; this is the handler shape.
python3 /absolute/path/to/script/agent_signal_bridge.py --source codex
```

Use the actual path to your stable checkout or the bridge bundled with your App. Moving a checkout after configuring hooks changes that path. The handler writes restricted local state under `~/Library/Application Support/Vibekey/AgentSignals/`, with atomic replacement, locking, validation and readback.

Do not post the plan's full output, raw input events, session files or local state folder in a public issue.

## Desktop compatibility reader

In a normal App session, the built-in Codex Desktop reader automatically polls local session metadata when available. **Turning off lighting does not turn off this local reader.** Quitting the App stops it. Developers who want a build without that reader can supply `desktopReader: nil` when constructing `AgentSignalStore` in `Sources/Vibekey/App/VibekeyApp.swift`.

The reader is restricted to the observed metadata version **`0.163.0-alpha.10.2`**, defined in `CodexDesktopSessionHeader.supportedVersion`. This is an observed source format, not a stable public API or a statement about the latest Codex version. Unsupported or malformed input stays unknown. It extracts allowlisted state and timing from files under `~/.codex/sessions`; these source files may contain private conversation content even though only typed metadata leaves the decoder.

Native hooks supply approval information. Desktop metadata supplements running freshness and reliable same-turn closure; it does not manufacture approval events. This publication does not install hooks or verify a live Claude Code connection on your machine.

## State and light behavior

| State | Meaning | Default lighting policy |
| --- | --- | --- |
| Running | A supported source reports current work | Steady supported mode at the configured running brightness; default 40% |
| Approval/attention required | A supported unresolved request needs attention | Higher brightness; default 80% |
| Real turn ended | Reliable source evidence closes that turn | Brief lower-brightness hint, default up to 20%, then restore |
| Failed/interrupted | Supported failure or interruption state | A bounded low-brightness hint when applicable, then restore |
| Unknown/stale | No usable current evidence | Preserve unknown; do not invent success |

The defaults describe policy, not a guarantee about the appearance of every firmware. Brightness is encoded in supported device steps; the app does not expose custom RGB or independent LED zones. Before borrowing lighting, it privately backs up the full supported payload, preserves opaque fields, and confirms writes by complete readback. A changed connection or manual configuration can invalidate restoration ownership.

`Stop` is a proposal to stop, not final success. A `TaskCompleted` proposal can still be vetoed and is not promoted to verified completion. A completed turn also does not establish that a user-facing task was accepted. Uncorrelated approvals remain unresolved or require review until reliable evidence clears them.

## 中文

灯光跟随是可选功能。桥接脚本可解析受支持的 Codex / Claude Code hook 元数据，但实际客户端是否加载 hooks、产生真实事件，必须分别核验。运行 `python3 script/agent_signal_bridge.py --plan` 只生成合并方案，不写配置、不安装服务、不改信任。方案包含本机路径与配置摘要，请私下审阅。

保留现有事件数组和处理器，按 Agent 的正常审阅与信任流程添加；不要整份覆盖配置，也不要复制他人的信任记录。运行时仅保存类型化状态、时间、顺序与哈希关联信息，不保存提示词、回复和工具参数原文。

**正常 App 启动后，内置 Desktop 兼容读取会自动观察可用的本地 session 元数据；关闭灯光跟随并不会关闭读取，退出 App 才会停止。** 开发者可在创建 `AgentSignalStore` 时传入 `desktopReader: nil`，构建不含该读取行为的版本。当前仅接受源码限定的 `0.163.0-alpha.10.2` 元数据格式；这不是稳定官方 API，也不表示当前最新版本。

原生回调提供审批状态，Desktop 元数据只补充运行新鲜度和同一轮的可靠结束。源码支持不等于当前电脑已实际接通。模拟只显示软件状态；真实审批、低电量及特定固件的灯效必须单独验证。本轮结束和完成提议都不等于整个业务任务验收通过。
