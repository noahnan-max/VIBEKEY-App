# Security and privacy / 安全与隐私

Please do not disclose credentials, raw Agent events, transcripts, device backups or personal macros in a public issue.

For a suspected vulnerability, use this repository's **Security → Advisories → Report a vulnerability** when private reporting is available. If that option is unavailable, open a minimal issue asking for a private reporting channel without including exploit details or personal data.

Useful redacted information includes the source revision, macOS version, component name, an expendable reproduction and whether physical hardware was involved. Share only the smallest necessary sanitized excerpt.

The App can send input and run workflows with the logged-in user's permissions. Device backup and runtime directories are personal data. The built-in Desktop reader observes local Agent session metadata while the normal App is running; lighting enablement is a separate setting. See [Agent integration](docs/AGENT_INTEGRATION.md) for the actual read and persistence boundaries.

No release in this initial source publication claims Apple notarization, independent security certification, or comprehensive firmware compatibility.

---

不要在公开 Issue 中披露凭据、原始 Agent 事件、会话正文、设备备份或私人宏。安全问题优先使用仓库 Security 页的私密漏洞报告入口；入口不可用时，只提交不含细节的联系请求。

提供源码版本、系统版本、组件与隔离复现即可，保留实体设备是否参与的信息。App 按当前用户权限发送输入和运行工作流，配置及恢复目录属于个人数据。正常运行时的 Desktop 元数据读取与灯光开关是两个行为，实际边界见 [Agent 接入说明](docs/AGENT_INTEGRATION.md)。
