# Daily preset / 日常操作预设

Version 0.16.1 source includes the portable daily profile from the saved AU05 setup. It contains six controls and twelve radial actions, without personal app paths, accounts, private URLs or device backup data.

![Native first-use preset guide / 原生首次使用预设说明](images/preset-setup-light.png)

## 六个操作位

| 位置 / Control | 初始行为 / Initial behavior |
| --- | --- |
| 上键 / Upper | 左 Control / Left Control |
| 中键 / Middle | Return |
| 下键 / Lower | Backspace |
| 旋钮按下 / Knob press | 打开轮盘，再按确认 / Open radial menu; press again to confirm |
| 左转 / Turn left | 向上滚动 19 行 / Scroll up 19 lines |
| 右转 / Turn right | 向下滚动 18 行 / Scroll down 18 lines |

旋钮的基础按键仍为右 Control；启用轮盘时，由单击轮盘入口接管。上下滚动幅度沿用保存的日常配置，可在 App 中分别调整。Control 的具体功能取决于前台应用或输入法已有的设置。

The knob's base key remains right Control; the enabled radial trigger takes priority. Each scroll amount remains adjustable. A bare Control key's effect depends on the foreground app or input method.

## 十二项轮盘动作

| 顺序 / Order | 动作 / Action | 映射 / Mapping |
| --- | --- | --- |
| 1 | 窗口总览 / Window overview | macOS Mission Control |
| 2 | 复制 / Copy | ⌘C |
| 3 | 粘贴 / Paste | ⌘V |
| 4 | 撤销 / Undo | ⌘Z |
| 5 | 全选 / Select all | ⌘A |
| 6 | 重做 / Redo | ⇧⌘Z |
| 7 | 打开 GitHub / Open GitHub | https://github.com |
| 8 | 进入或退出全屏 / Toggle full screen | ⌃⌘F |
| 9 | 静音切换 / Toggle mute | 系统音量 / System audio |
| 10 | 显示全部窗口 / Show all windows | ⌃↑ |
| 11 | 整个屏幕截图 / Entire-screen screenshot | ⇧⌘3 |
| 12 | 选择区域截图 / Area screenshot | ⇧⌘4 |

每页 8 项；转动或滚动可连续跨页选择。仅打开预览不会执行动作。以上快捷键遵循常见 macOS 映射，系统自定义设置和目标应用可能改变实际行为。

There are eight sectors per page; rotation/scrolling continues across pages. Opening a preview does not execute an action. Custom system shortcuts and target applications can change the effect of a mapping.

## 首次加载和已有配置

- 只有缺少对应配置文件时才创建预设。完整保存并读回后，首次电脑端动作和轮盘才会采用预设状态。
- 已有配置、用户保存的空列表，以及明确关闭的开关保持原样。损坏、不可读或未来版本的文件保留原文件，相关功能暂停。
- 预设加载只写本机 App 配置，不自动改写 AU05 设备内快捷键、固件或灯光。
- 首次使用仍需连接 AU05，并允许电脑端快捷键所需的辅助功能权限。没有权限时，预设可见但不能据此宣称跨应用操作可用。

Defaults are created only for missing configuration files and activated after a successful save/readback. Existing settings, saved empty lists and explicit disabled choices are preserved. Unreadable or unsupported files remain intact and the affected feature stays inactive. Loading a preset performs no device writes or host actions. Device connection and Accessibility permission remain necessary for the relevant runtime behavior.
