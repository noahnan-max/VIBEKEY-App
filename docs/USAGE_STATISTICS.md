# 使用统计 / Usage statistics

## 中文

0.21.1 的「使用统计」首页显示累计收录量、观察与估算来源、麦克风使用时长、操作片段、活跃天数、连续天数和每日热力图。可以查看某一天的汇总，或向前浏览较早的记录。

首次使用时，统计保持关闭。阅读页面上的本机统计用途说明，点击「开启本机统计」，或打开「自动统计」开关后，App 才开始相应观察；已有宏功能的辅助功能权限不会代替这次选择。关闭统计会保留已有汇总。旧研发数据的自动开启标记也不会被直接当成这次用途的同意。

启用后，App 只读检测已连接 AU05 / VIBEKEY 麦克风的使用状态；不会创建音频客户端、读取音频样本、请求麦克风权限、改变输入设备或接管语音识别。原按键行为先执行，统计在独立队列处理。原有输入法或语音软件继续负责识别、润色和输入。

字数口径是**本段出现过的非空白字符累计量**，按 Unicode 字符计数。文字在录音过程中出现就会更新，不必等到结束；后续缩短、删除或润色不扣回，相同整段草稿不会反复累计。一次结束仅入账一次，页面上的临时进度不会与已保存数据重复计算。持续使用会被分成有界的观察片段，因此次数不等于按键次数。

焦点短暂离开时只重试原输入框，不追踪到其他输入框，也不改变光标、焦点、输入源或剪贴板。无法读取文字时，可按麦克风使用时长估算，并明确区分「观察」和「时长估算」；已识别的密码框不估字数。麦克风使用包含停顿、静音及可能的会议时段，估算不能证明期间一直发声。同框手工编辑、极快发送及未开放可访问文字的应用也可能造成误差。

「估算节省时间」使用可调整的打字速度换算字符量，再减去对应操作时长。它是方法明确的估算，可以为负，不是经过测量的个人生产率提升。

本机 `~/Library/Application Support/Vibekey/UsageStatistics/usage.json` 仅保存偏好、每日字数、时长、来源和失败类别计数，不保存原文、音频、输入框内容或应用对话。文字和去重状态只在有界会话内存中短暂存在；统计本身不联网。目录和文件使用私有权限。已有日期与未知缺口保留，不补造历史漏记；损坏或未来版本文件不会被默认数据覆盖。

检查覆盖合成输入、实时累计、重复去重、删除不扣回、焦点恢复、估算来源、暂停/退出保存、首次选择及历史兼容。自有输入框或模拟器通过，不代表每种第三方语音软件都完成逐字对照；请结合来源标签理解结果。

## English

The 0.21.1 usage home shows cumulative received characters, observed versus estimated coverage, microphone-use duration, session segments, active days, streaks and a daily activity grid. Select a day or browse earlier periods to inspect aggregate history.

Collection starts **off**. Read the local-use explanation, then explicitly enable it. Existing Accessibility permission for macros does not grant the new observation purpose. Disabling collection keeps history. A legacy development build's automatic enabled flag alone does not count as consent.

Once enabled, a read-only monitor observes the connected AU05/VIBEKEY input device's activity. It opens no audio client, reads no audio samples, requests no microphone permission and does not change the input device or speech pipeline. Original key dispatch runs first; observation stays on its own queue. Your existing input method or dictation software continues to recognize and insert speech.

The character metric is cumulative, non-whitespace Unicode characters received during a bounded segment. Progress appears while recording; later shortening or deletion does not subtract received input, and repeated whole drafts are deduplicated. Provisional progress is merged once into the saved ledger. Sustained use can create several bounded segments, so session totals are not physical key-press counts.

Temporary focus changes retry the originally captured field without following another field or changing text, caret, focus, input source or clipboard. If text is unavailable, microphone duration can produce an explicitly labeled estimate. Known secure fields are excluded from character estimation. Duration includes pauses, silence and possible meeting use; manual edits, rapid submission and inaccessible applications can introduce error.

Estimated time saved converts counted characters using the chosen typing rate and subtracts corresponding operation duration. It can be negative and is not a measured productivity claim.

Only preferences and daily counts, duration, sources and failure-category totals are stored in the private local `UsageStatistics/usage.json` file. Raw text, audio and conversations are not stored. Bounded in-memory text state is temporary; the statistics feature sends no network requests. Historical gaps remain unknown, and damaged or future-version files are preserved.

Synthetic readers and owned targets test the counting and non-interference rules. These checks do not prove exact character coverage for every third-party dictation application.
