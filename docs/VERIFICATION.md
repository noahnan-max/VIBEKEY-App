# Initial publication verification / 初次开源验证

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
