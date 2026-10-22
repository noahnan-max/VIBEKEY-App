# Login launch and signed updates / 登录启动与签名更新

The App uses macOS `SMAppService.mainApp` for login launch and Sparkle 2.10.0 for signed, user-confirmed updates. There is no always-relaunching helper: quitting VIBEKEY keeps it quit until the next launch/login.

Automatic checks default to once per day. Scheduled update discovery is handled by Sparkle's Gentle Reminders delegate and never presents the standard update alert. It updates the menu-bar/settings unread badge and the inline version/notes instead. Manual checks use the information-only API and also report their result inline. Only **Update and relaunch** invokes Sparkle's standard consent/download/install flow.

The update feed is `https://raw.githubusercontent.com/noahnan-max/VIBEKEY-App/main/appcast.xml`. The feed, embedded release notes and archive are authenticated with the public Ed25519 key embedded in the App. The signing private key remains in the publisher's local Keychain under the project-specific account; it is never copied into Git or an App. System profiling, automatic downloads and automatic installation are disabled. A download or signature failure leaves the installed App intact.

Before confirming Sparkle's final relaunch, VIBEKEY flushes its configuration, cancels active host actions, waits for device work and restores borrowed lighting. A failed cleanup postpones installation and exposes a retry action. It never uses force termination to bypass recovery.

## Preparing a release

1. Update `release/version.json`: use a new human-readable version and a strictly increasing numeric build. Do not reuse a build number for changed executable code.
2. Write `release/notes-<version>.txt`. Describe concrete changes; the feed carries these notes as plain text for inline display and the confirmation window.
3. Build with `./script/build_and_run.sh --build-only`, using the publisher's existing code-signing identity for a release. Run the relevant regressions and inspect the actual App.
4. Run `python3 script/prepare_release.py`. It checks the bundle/version/policy, verifies code signatures, packages with symlink-preserving `ditto`, signs the archive/feed with the local Sparkle key, and creates hashes and release metadata under `dist/release-<version>/`.
5. With the publisher's authorization, upload the archive and hashes to the corresponding GitHub Release. Copy the prepared signed `appcast.xml` into the repository root and commit/push it only after the exact download URL is live. Never edit signed feed bytes afterward without signing again.
6. Download the published archive anonymously, compare its hash and recheck signature/feed metadata. Check both the new-update UI on an older controlled App and the current-version result.

`prepare_release.py` does not publish, install, create credentials, or configure a recurring release task. Back up the publisher's signing material through an appropriate protected process; losing the key can require a manual reinstall or a separately verified key-rotation process. Do not export it into the repository.

The official 0.16.1 archive completed Developer ID signing, hardened runtime, secure timestamps, Apple notarization and stapling before its final Sparkle signatures were generated. The same archive was installed and launched on a second MacBook, with human confirmation of its window and complete 3D artwork. This is distinct from the default local-development build, which does not automatically notarize its output. For future Developer ID releases, finish Apple processing and Gatekeeper validation before packaging and signing the final update bytes. Each target Mac still manages its own permissions. See [the dated verification record](VERIFICATION.md).

## 中文

登录启动由 macOS 原生主 App 登录项管理，用户可以在 App 中开关；自动启动留在菜单栏，主动打开才显示主窗口。正常退出后不会自动反复拉起。

后台每天静默检查，不弹更新窗口；菜单栏和设置入口显示未读标记。手动检查也在设置页显示结果。用户先看版本和主要更新点，再主动点击「更新并重新启动」，才进入确认、下载、签名校验、替换和重开流程。更新包和 feed 均有签名，私钥只在发布者钥匙串中，不进入源码或安装包；自动下载安装与系统画像始终关闭。

后续维护时，递增 `release/version.json` 的版本及 build，撰写对应更新说明，构建并运行必要验证，然后用 `prepare_release.py` 生成签名发布文件。经发布授权后先上传真实下载包，再发布与该包完全对应的签名 feed。脚本本身不外发、不安装、不自动创建凭据或定时发布。

从 0.15.3 首次升级需要手动安装一次含检查器的版本。用户的按键、宏和轮盘仍保存在本机。新版安装前先保存配置并正常恢复硬件状态，未确认的恢复会阻止替换。

正式 0.16.1 归档先完成 Developer ID 签名、hardened runtime、可信时间戳、Apple 公证与票据装订，再对最终包体和更新源生成 Sparkle 签名；同一包已在另一台 MacBook 安装、正常启动并确认完整 3D 显示。源码的默认本地构建不会自动公证。后续正式包也须在 Apple 处理完成后签署最终字节，已有下载包不复用旧签名覆盖；各台 Mac 的辅助功能等权限仍由当地用户管理。

References: [Apple ServiceManagement](https://developer.apple.com/documentation/servicemanagement/smappservice), [Sparkle gentle reminders](https://sparkle-project.org/documentation/gentle-reminders/), [signed publishing](https://sparkle-project.org/documentation/publishing/).
