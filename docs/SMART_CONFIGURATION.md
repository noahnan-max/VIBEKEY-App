# AU05 智能配置 / AU05 intelligent configuration

## 中文

在 AU05 设备页点击「智能配置」，或使用「设备 → 智能配置…」（⌥⌘I）。用自然语言描述需要的按键、宏和普通灯光设置，先查看具体差异，再决定是否「备份并应用」。仅生成、测试连接或查看预览都不会写入设备。

### 模型接入

- **通用 API**：自行填写支持 function calling 的 OpenAI Chat Completions 兼容地址、服务商提供的模型 ID 和自己的 API Key。本机无密钥服务可留空；远程地址必须为 HTTPS，HTTP 仅允许本机回环。拒绝带用户名、密码、查询参数的地址及重定向。
- **本机 Codex 登录**：可选使用已安装、已登录且支持所需隔离参数的官方 Codex CLI。模型可留空使用 CLI 默认值。VIBEKEY 不读取、复制或保存 OAuth token；不兼容的 CLI 或缺少登录会停止调用。该独立规划调用使用现有账户额度，禁止命令、MCP、插件、记忆和网页搜索，不接入已有聊天。
- 保存设置只表示本机参数已保存；「模型调用已验证」必须在真实调用成功后显示。连接测试会发送一条不要求设备修改的合成请求，不读取设备。

公开版的模型目录和钥匙串命名与私人研发配置分开，首次不导入公司地址、账户或密钥。API Key 仅保存在 macOS 钥匙串中，按端点与本机目录隔离；授权读取后只在当前进程内存中复用，同端点并发请求共用一次读取。更换或移除密钥会失效旧缓存。系统授权由本人在 macOS 窗口完成。

调用时只发送本次需求与允许的 AU05 状态：六位置的快捷键、已有宏的占用/步骤数量及已知灯光字段。不会发送原有宏的正文、设备私有标识、备份、使用统计或其他应用内容。用户在需求中自行填写的文字会发送给所选服务，请按该服务的条款和费用使用。错误提示按兼容性、授权、限流等分类，不显示服务端原始错误或密钥。

### 可生成的配置

| 类型 | 范围和保存位置 |
| --- | --- |
| 设备快捷键 | 六个位置，支持已验证的快捷键组合、滚动及不执行动作；设备组合最多四个 entry。写入并读回后保存在 AU05。 |
| Mac 宏 | 快捷键、等待、滚动、音量和静音，最多 64 步，单步等待 0–30 秒、累计不超过 60 秒。保存在这台 Mac，VIBEKEY 运行时执行。 |
| 普通灯光 | 全灭、全亮、工作模式及全亮模式 0–20 亮度。RGB、逐灯颜色、底灯充电/低电量等未验证能力不在此范围。 |

智能规划不允许 shell、应用启动、网址、文件访问、固件升级、重置、配对或连接模式操作。原宏编辑器已有的其他动作不会因此被删除，但模型不能新增这些动作。模糊或超出范围的需求应返回澄清，不能猜测执行。

### 预览、应用与恢复

模型结果先通过固定 schema 和确定性校验。未知字段、错误工具名、重复位置、超范围动作或不一致参数会被拒绝。DeepSeek 使用兼容的自动工具选择，但仍必须返回唯一合法的配置工具；自动选择不等于允许执行任意工具。

预览会列出键位、宏、灯光以及启用开关的变化；替换已有全局宏或停止 Agent 灯光跟随等影响需要额外勾选确认。按应用宏或轮盘占用导致的冲突必须先处理。设备映射与 Mac 宏的保存位置和退出后行为明确区分。

「备份并应用」会重新读取并比较预览基线，预约现有唯一 DeviceSession，完整备份六个设备快捷键、灯光和本机宏/相关开关，再写入并完整读回。备份失败、配置变化或断连时停止；恢复只在原连接与仍匹配的状态下进行，不盲目覆盖并发修改。需要恢复时，窗口保留本机备份入口，正常退出和更新会尊重未完成的配置事务。

此公开版本只提供 AU05 智能配置。不同服务的工具调用兼容性、额度和账户权限需要各自测试；本项目不提供托管模型账户或密钥。真实模型连接、合成设备事务、公开构建、实体按键执行及其他 Mac 安装分别验收，详见[验证记录](VERIFICATION.md)。

## English

Open **智能配置** on the AU05 page, or use **Device → Intelligent configuration…** (⌥⌘I). Describe keys, macros or ordinary lighting; inspect the concrete preview and choose whether to back up and apply. A connection test, generated plan or preview does not write to the device.

Use your own function-calling OpenAI Chat Completions-compatible service, endpoint, model ID and API key. Remote services require HTTPS; HTTP is limited to loopback, redirects are blocked and credentials cannot be embedded in the URL. An optional installed official Codex CLI can reuse your existing login through an independent ephemeral, read-only planning call with tools, MCP, plugins, memories and web search disabled. Unsupported CLI isolation fails closed; no OAuth token is copied. Calls use the selected provider/account's quota.

Public model preferences and Keychain selectors are separate from private development settings. No company endpoint, account or credential is imported. Keys stay in macOS Keychain; successful reads are reused only in process memory, scoped to the endpoint. Concurrent reads coalesce, and changing/deleting a key invalidates the old cache. Saved settings and verified inference are different states.

The selected model receives the explicit request and allowlisted AU05 state: six shortcuts, macro occupancy/step counts and known lighting fields. Existing macro text, device IDs, backups, usage statistics and other applications' text are excluded. Text you put in the request is sent to your chosen service.

Supported plans include device shortcuts/scroll/no-op actions, bounded Mac macros of shortcut/wait/scroll/volume actions, and validated ordinary lighting modes/brightness. Mac macros require VIBEKEY to keep running. Shell, app launch, URLs, files, firmware, reset, pairing, RGB and unsupported lighting semantics cannot be introduced by the model. Ambiguous or unsupported requests must ask for clarification.

Strict schema and semantic validation reject unknown fields, wrong tools, conflicts and unsafe parameters. DeepSeek's automatic tool selection still requires one authorized configuration tool. Preview lists native versus Mac behavior and any effects on existing macros or Agent lighting; sensitive configuration changes require acknowledgement.

Apply re-reads the preview baseline, reserves the sole device session, makes a durable complete backup, writes permitted fields and checks the full result. Failures and disconnections stop the operation; rollback checks connection and state before each restore. Backups and recovery state remain local. Shutdown and updates preserve unresolved transactions.

Provider compatibility, real hardware execution and installation on another Mac require their own evidence. See [Verification](VERIFICATION.md).
