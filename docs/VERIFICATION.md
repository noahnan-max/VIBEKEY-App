# Verification / 验证记录

## 0.16.0 — login launch and quiet signed updates

The following checks cover the new production code and isolated updater fixtures. They do not establish Apple notarization, another Mac's permissions, or a physical reboot/login.

| Check | Result | What it establishes |
| --- | --- | --- |
| Release build and bundle integrity | PASS | Apple-silicon 0.16.0 build 1600, including the nested Sparkle components, passes deep/strict code-signature verification. The local publisher identity is not an Apple Developer ID notarization. |
| Login state and launch-event checks | PASS, 11 checks | Enabled/disabled/error/approval state is read back without optimistic success; both native login-event forms select background launch. These fixtures do not create real login entries. |
| Installed login registration | PASS, scoped | VIBEKEY is visible in macOS Open at Login and the installed App reads its native login status as enabled. The actual in-App switch interaction was not run because the UI automation tool retained the previous App identity. |
| Installed background cold launch | PASS | The installed 0.16.0 App runs from Applications as an accessory with zero ordinary windows, and existing shared configuration hashes are unchanged. This uses the explicit background launch path; a real reboot/login is NOT_RUN. |
| Quiet background update discovery | PASS, isolated real App | A signed loopback feed produces an in-App unread indicator and inline release notes without an update alert. The server receives zero archive requests before explicit consent. |
| Confirmed replacement and relaunch | PASS, isolated real App | The production update Store downloads a signed version 2 after consent, invokes its preparation callback before replacement, and relaunches the actual replacement at version 2. No production configuration or hardware access. |
| Invalid archive signature | PASS, isolated real App | Sparkle rejects the archive, version 1 remains installed, and replacement/preparation does not occur. |
| Native rendering and artwork | PASS, 34 snapshots | Light/dark production views load the complete original AU05 3D render. The signed App contains the expected artwork bytes; there are no device writes or host actions in the render probe. |
| Existing isolated regressions | PASS | 22 hardware suites, 39 battery checks, 50 Desktop metadata checks and 38 Python bridge/recovery tests. |
| Updated source boundary scan | PASS with one classified public-key finding | Gitleaks flags the intended Ed25519 verification key as a generic API key. It matches the publisher tool's public-key output and the installed App; no sensitive finding remains. The third-party license is preserved verbatim. |
| Updated public feed and download | PENDING | The production signing tool is waiting for the publisher's local Keychain authorization. Version 0.16.0 and its signed feed have not yet been published. |
| New public-identity Accessibility permission | PENDING on publisher's Mac | The installed App reports that permission has not been granted. Cross-app macros and input posting are not accepted by the checks above. |

中文：已验证静默提醒、确认后替换重开、错误签名拒绝，以及本机登录项开启和后台无主窗口启动。真实重启登录、App 内开关点击、辅助功能重新授权、生产更新包发布、其他 Mac 安装与 Apple 公证仍保留各自的未运行或待完成状态。

## Initial publication / 初次开源

Scope: AU05-only source based on VIBEKEY 0.15.3, published independently of the private development history. This record describes checks of the public source, not acceptance of every physical-device or target-application behavior.

| Check | Result | What it establishes |
| --- | --- | --- |
| Portable command-line build | PASS | The AU05 core, diagnostic executable and SwiftUI/AppKit `.app` compile on Apple silicon with Swift 5.8.1 and the installed macOS SDK. No private certificate is required. |
| App bundle integrity | PASS | The generated local-development bundle passes `codesign --verify --deep --strict`. It uses an ad-hoc signature. |
| Existing isolated hardware suites | PASS, 22 suites | Protocol, routing, workflows, onboard transactions, autosave, radial input, lighting and Agent state negative cases pass. No physical device writes or system input posting. |
| Battery fixtures | PASS, 39 checks | In-memory battery interpretation, freshness, polling and alert-related Store behavior. No actual low-battery device trigger. |
| Desktop metadata fixtures | PASS, 50 checks | Version-restricted metadata, privacy sentinels, freshness, ordering and source rejection. No live Agent-client acceptance. |
| Python bridge and recovery | PASS, 38 tests | Event filtering, ordering, restricted persistence, readback and recovery using owned test directories. No production hook installation. |
| Native rendering | PASS, 34 snapshots | Production AU05 views rendered with isolated example configuration in light/dark appearances and regular/minimum desktop sizes. No AU05 capture, device writes or host actions. |
| README image inspection | PASS | Key editor in both appearances and radial settings were visually inspected. All use original schematic artwork. |
| Source secret scan | PASS | Gitleaks scan found no secret findings in the prepared source tree. This is a scoped scan, not an independent security certification. |
| Public GitHub readback | PASS | The repository is anonymously readable, GitHub recognizes MIT, and both README files, the license and all three screenshot downloads match local hashes. |
| Fresh GitHub clone build | PASS | A new shallow clone of the published source builds the `.app` and passes signature-integrity verification without the original working tree's generated files. |
| Public-source boundary | PASS | No private keyboard implementation, retired speech/IME source, runtime data, device backup, signing material, manufacturer binary or extracted product image is included. |
| SwiftPM on the local CLT installation | BLOCKED by platform discovery; XCTest NOT_RUN | This Command Line Tools installation cannot resolve `xcrun --show-sdk-platform-path`. The supported direct-`swiftc` build and isolated checks passed instead. XCTest on a full Xcode toolchain remains separate. |
| Physical AU05 triggers and cross-app execution of this public build | NOT_RUN | This publication did not take ownership of or write to the in-use device. |
| Genuine approval-state lighting and actual low-battery trigger | NOT_RUN | Mock events and logical thresholds do not substitute for these physical scenarios. |
| Other Macs, Intel and other operating systems | NOT_RUN | No broader installation/architecture compatibility claim. |
| Apple Developer ID signing and notarization | NOT_RUN | This source publication supplies a local-development build path, not a notarized installer. |

Reproduce the isolated checks with:

```sh
./script/build_and_run.sh --build-only
./script/run_tests.sh
```

The suite runners retain detailed evidence under ignored local `.build/` and `evidence/` directories. Those reports may contain absolute local paths and are deliberately not committed. Screenshots in this repository contain only isolated example configuration.

中文：以上结果只覆盖本次公开源码、构建和隔离验证。22 组硬件逻辑、39 项电量、50 项 Desktop 元数据及 38 项 Python 桥接检查通过；原生渲染覆盖 34 张图，未接管实体设备。实物按键、目标应用消费、真实审批灯、实物低电量、其他 Mac 安装及 Apple 公证均未在本次发布中验收，不将模拟或签名检查升级为这些结果。
