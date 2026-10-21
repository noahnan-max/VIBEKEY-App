# Getting started / 开始使用

[English README](../README.md) · [中文介绍](../README.zh-CN.md)

## English

### Build and launch

Use an Apple silicon Mac with macOS 13.3+, Swift 5.8+ and Apple's macOS SDK. Install Command Line Tools using `xcode-select --install` if they are not already installed, then follow the system installer. The first build downloads and checksum-verifies Sparkle 2.10.0 from its official GitHub release.

```sh
./script/build_and_run.sh --build-only
open dist/VIBEKEY.app
```

The script targets arm64 and uses `swiftc`, avoiding a requirement for the full Xcode application's platform directory. It refuses to replace its own running output bundle and never terminates another process. An older development bundle is retained under `.build/previous-bundles/` when replaced.

The local build uses an ad-hoc signature unless you explicitly provide `VIBEKEY_SIGNING_IDENTITY`. Signing verification checks bundle integrity; it does not perform Apple notarization or grant Accessibility access. Rebuilding may change the signature's identity as seen by macOS. Review any system prompt before granting access.

### Connect and configure

1. Connect the AU05 through a supported data connection. Charge-only cables do not carry HID data. Do not run competing device-control apps against it at the same time.
2. Open **开始使用** and check the connection information. Disconnected and unread values stay unknown rather than showing a made-up zero.
3. Open macOS **System Settings → Privacy & Security → Accessibility**, then allow this VIBEKEY build when you want it to send keyboard or mouse events. Configuration readback and event dispatch are separate checks.
4. In **按键与旋钮**, click the physical control in the device schematic. The **快捷键** editor changes supported device fields. **宏与工作流** defines Mac-side actions. Read the labels before enabling a behavior.
5. Add a simple action first and test it in an expendable document. App-specific bindings use application bundle identifiers; the selected app must be the foreground target.
6. In **快捷轮盘**, select an activation mode and add entries. The menu uses pages of eight, supports reverse page transitions, and can be previewed without action execution. Enable it separately when ready.
7. Close the window to keep running in the menu bar. Use **退出 VIBEKEY** to quit. If a configuration or restoration is unconfirmed, the App may keep running and ask you to resolve it rather than claim a successful shutdown.

The App's normal hardware defaults remain pass-through until you opt into custom behavior. Firmware-specific Fn encodings, unsupported oversized device shortcuts and unknown light fields are not guessed.

### Data locations

| Location | Contents |
| --- | --- |
| `~/Library/Application Support/Vibekey/` | Local workflows, radial configuration, state, diagnostics and private recovery files |
| `~/Library/Application Support/Vibekey/AgentSignals/` | Optional hook inbox, ordering/epoch metadata and hashed state correlation |
| App preferences for `io.github.noahnan-max.VIBEKEY` | Appearance and other App preference flags |
| `~/Library/Caches/Vibekey/OwnedProbes/` | Isolated native rendering fixtures when explicitly invoked |
| Project `.build/`, `dist/`, `evidence/` | Generated build and test output; ignored by Git |

Back up your own settings before experimentation. The public App uses the `Vibekey` support directory for compatibility; do not run another VIBEKEY version against it simultaneously. The runtime ownership lock prevents a second cooperating instance from taking ownership. No migration or cleanup script is automatically run by this public build.

### Troubleshooting

| Symptom | Check |
| --- | --- |
| AU05 is not ready | Data cable/receiver, power, connection state and competing HID owners. Transport support is firmware-specific. |
| Device is connected but a Mac action does nothing | Accessibility permission, explicit feature enablement, foreground app and its shortcut mapping. |
| A workflow edit is not active | Validation errors, automatic-save status and the enable switch. The last valid saved configuration stays active. |
| Battery seems frozen | Sample freshness and whether the device is connected, ready and idle. Polling is not continuous while editing. |
| Agent state is unknown | Real events, hook trust, file permissions, freshness and supported Desktop version. Configuration installation alone is not an event. |
| Lighting does not change | Device readiness, the follow switch, actual source state, supported fields and confirmation status. Simulation never drives hardware. |
| Quit is delayed | Pending writes, unsaved invalid configuration or unconfirmed restoration. Resolve the displayed error; do not use forced termination as the normal path. |

The diagnostic target contains explicit device-access modes, including a write/read/restore experiment. It is not part of the normal test runner. Inspect `Sources/VibekeyProbe/main.swift` before running diagnostic options against real hardware.

## 中文

### 构建与启动

使用 Apple silicon Mac、macOS 13.3+、Swift 5.8+ 和 Apple macOS SDK。尚未安装开发工具时，可执行 `xcode-select --install`，按系统安装程序完成。首次构建会从官方 GitHub release 下载并校验 Sparkle 2.10.0。

```sh
./script/build_and_run.sh --build-only
open dist/VIBEKEY.app
```

脚本直接使用 `swiftc` 构建 arm64 版本，不依赖完整 Xcode 的平台目录。它不终止其他进程，也不覆盖正在运行的自身输出包；被替换的旧开发包保存在 `.build/previous-bundles/`。

默认是 ad hoc 本地开发签名，只有显式指定 `VIBEKEY_SIGNING_IDENTITY` 才使用你自己的既有身份。签名完整性检查不等于 Apple 公证或辅助功能授权，重新构建后可能需要重新授权。

### 连接与配置

1. 用受支持的数据连接方式连接 AU05，避免只有充电功能的线材，也不要同时运行争用 HID 的设备控制软件。
2. 在「开始使用」查看连接信息。未连接或未读出的字段保留未知。
3. 需要发送键鼠事件时，在「系统设置 → 隐私与安全性 → 辅助功能」允许当前构建的 VIBEKEY。读到设备和成功执行动作是两项不同检查。
4. 打开「按键与旋钮」，点击示意图上的操作位置。「快捷键」编辑已支持的设备字段，「宏与工作流」编辑电脑端行为。
5. 先添加一个简单动作，在可丢弃的示例文档中验证。按应用映射使用 bundle identifier，目标应用须处于前台。
6. 在「快捷轮盘」选择入口、添加动作，先检查预览，再独立启用。每页八项，正反方向均可连续跨页。
7. 关窗后继续在菜单栏运行，选择「退出 VIBEKEY」正常结束。尚有配置或恢复未确认时，App 可能保持运行并提示处理，不会把强制退出作为成功恢复。

默认保留原设备行为，自定义功能由你选择启用。不猜测未确认的 Fn 编码、超出设备容量的组合键或未知灯光字段。

### 数据与排查

本机配置、诊断和私人恢复文件位于 `~/Library/Application Support/Vibekey/`；Agent 元数据位于其中的 `AgentSignals/`。外观等偏好随 `io.github.noahnan-max.VIBEKEY` 保存。显式运行的界面探针使用 `~/Library/Caches/Vibekey/OwnedProbes/`，构建与测试输出在项目 `.build/`、`dist/` 和 `evidence/`，均不提交 Git。

公开 App 为兼容使用原有 `Vibekey` 数据目录，不要让另一版本同时访问；协作实例通过运行锁限制第二个所有者。构建不会自动迁移或清理个人数据。

- **连接不上**：核对供电、数据线或接收器、连接状态及其他 HID 占用；不要假定所有固件和连接方式都已覆盖。
- **动作无效**：核对辅助功能权限、功能启用开关、前台应用及其快捷键。
- **编辑未生效**：检查校验和自动保存状态；无效草稿不会替代最后有效配置。
- **电量不更新**：查看新鲜度和设备是否就绪、空闲；编辑设备期间不会持续抢占轮询。
- **Agent 显示未知**：检查真实事件、hooks 信任、文件权限、新鲜度及 Desktop 版本，配置安装不是实际事件。
- **灯光不变**：核对跟随开关、连接、真实状态和读回确认；模拟不会驱动物理灯。
- **退出被延迟**：先处理待写入、无效配置或恢复错误，正常退出前保留恢复机会。

诊断目标包含真实设备访问及写入读回实验，不属于默认测试入口。运行前先阅读 `Sources/VibekeyProbe/main.swift`，不要把诊断选项当作普通逻辑测试。
