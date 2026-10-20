# Contributing / 参与贡献

Thank you for improving VIBEKEY. Small, reproducible changes are easiest to review.

1. Open an issue describing the behavior, expected result, source revision, macOS version, hardware firmware if known, and connection type. Use an expendable example rather than a personal macro or conversation.
2. Fork the repository and create a focused branch. Keep unrelated formatting and generated files out of the patch.
3. Run `./script/build_and_run.sh --build-only` and `./script/run_tests.sh` on an Apple silicon Mac. Record exactly what ran and any failing or unrun checks.
4. For UI changes, inspect the actual affected native view in light and dark appearances. For transport changes, provide protocol reasoning and isolated negative cases before any physical testing.
5. In a pull request, explain the concrete problem, resulting behavior, validation and remaining compatibility limits. Do not describe a mock transport or screenshot as physical acceptance.

Keep one AU05 transport owner. Do not bypass validation, backup, readback, runtime ownership, cancellation or restoration checks to make a test pass. Device firmware changes and destructive experiments are not normal tests.

Never commit App bundles, `.build`, `dist`, runtime state, device backups, credentials, private signing materials, transcript files, or manufacturer installers. New third-party dependencies and artwork need an explicit source and compatible license. Original contributions are submitted under this repository's MIT license.

---

欢迎提交可复现的问题、文档修订、辅助功能优化和兼容性证据。请提供源码版本、macOS、已知固件和连接方式，用隔离示例描述问题，不附私人宏或对话原文。

修改保持聚焦，运行公开构建和测试入口，并明确实际运行、失败及未运行的项目。界面变化检查真实原生页面及浅深色；协议变化先补隔离反例，再讨论实物验证。模拟、截图和编译不能替代实体验收。

保留单一设备所有权、参数校验、私人备份、写入读回和恢复边界。不提交生成包、用户配置、硬件备份、密钥、签名材料、session 文件或原厂安装包。新增依赖和素材需有清晰来源及兼容许可，原创贡献按 MIT 协议提交。
