import Foundation

/// Presets produce ordinary workflow steps. Browsing never writes configuration
/// or executes an action, and no extra persistence format is introduced.
public enum ActionCategory: String, CaseIterable, Identifiable {
    case windows, editing, browser, finder, navigation, screenshots, system, controls, applications
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .windows: return "窗口与桌面"
        case .editing: return "文字与编辑"
        case .browser: return "浏览器与标签页"
        case .finder: return "文件与访达"
        case .navigation: return "阅读与光标"
        case .screenshots: return "截图"
        case .system: return "系统与输入法"
        case .controls: return "音量与滚动"
        case .applications: return "打开或切换应用"
        }
    }
    public var symbol: String {
        switch self {
        case .windows: return "macwindow.on.rectangle"
        case .editing: return "text.cursor"
        case .browser: return "globe"
        case .finder: return "folder"
        case .navigation: return "arrow.up.arrow.down"
        case .screenshots: return "camera.viewfinder"
        case .system: return "keyboard"
        case .controls: return "speaker.wave.2"
        case .applications: return "square.grid.2x2"
        }
    }
}

public struct ActionPreset: Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let category: ActionCategory
    public let recommended: Bool
    public let sourceURL: String?
    public let step: WorkflowStep

    public init(id: String, title: String, detail: String, category: ActionCategory,
                recommended: Bool = false, sourceURL: String? = nil, step: WorkflowStep) {
        self.id = id; self.title = title; self.detail = detail; self.category = category
        self.recommended = recommended; self.sourceURL = sourceURL; self.step = step
    }
    public var shortcutLabel: String? {
        step.kind == .shortcut ? RecordedShortcut(keyCode: step.keyCode, modifiers: step.modifiers).label : nil
    }
    public var onboardShortcut: RecordedShortcut? {
        guard step.kind == .shortcut else { return nil }
        let shortcut = RecordedShortcut(keyCode: step.keyCode, modifiers: step.modifiers)
        guard (try? AU05OnboardShortcut.entries(for: shortcut)) != nil else { return nil }
        return shortcut
    }
    public func makeStep(id: UUID = UUID()) -> WorkflowStep {
        var copy = step; copy.id = id; return copy
    }
    public func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: { $0.isWhitespace })
        let text = [title, detail, category.title, shortcutLabel ?? "", step.argument, id].joined(separator: " ")
        return terms.allSatisfy { text.localizedStandardContains(String($0)) }
    }
}

public enum ActionCatalog {
    public static let apple = "https://support.apple.com/zh-cn/102650"
    public static let missionControl = "https://support.apple.com/zh-cn/guide/mac-help/mh35798/mac"
    public static let safari = "https://support.apple.com/zh-cn/guide/safari/cpsh003/mac"
    public static let chrome = "https://support.google.com/chrome/answer/157179?co=GENIE.Platform%3DDesktop&hl=zh-Hans"
    private static let cmd: UInt64 = 0x00100000, shift: UInt64 = 0x00020000
    private static let option: UInt64 = 0x00080000, control: UInt64 = 0x00040000

    public static let presets: [ActionPreset] = {
        var values: [ActionPreset] = []
        func key(_ id: String, _ title: String, _ category: ActionCategory, _ code: UInt16,
                 _ flags: UInt64 = cmd, _ detail: String = "作用于当前前台应用，需该应用支持。",
                 recommended: Bool = false, source: String = apple) {
            values.append(ActionPreset(id: id, title: title, detail: detail, category: category,
                recommended: recommended, sourceURL: source, step: WorkflowStep(kind: .shortcut, keyCode: code, modifiers: flags)))
        }
        key("windows.previous-app", "切回上一个应用", .windows, 48, cmd, "在最近使用的两个应用之间切换；不是按固定顺序遍历全部应用。", recommended: true)
        key("windows.next-window", "切换同一应用的窗口", .windows, 50, cmd, "切到当前应用的下一个窗口；使用 macOS 默认窗口切换键。", recommended: true)
        key("windows.overview", "显示全部窗口", .windows, 126, control, "打开调度中心（Mission Control）；需系统中启用 ⌃↑。", recommended: true, source: missionControl)
        values.append(ActionPreset(id: "windows.rotary-overview", title: "窗口总览 · 旋钮选窗",
            detail: "打开 macOS 原生 Mission Control（F3）。作为轮盘的独立动作时，转动旋钮选择当前桌面的窗口，按下旋钮确认，轮盘取消键或 Esc 取消。",
            category: .windows, recommended: true, sourceURL: missionControl, step: WindowOverviewAction.step))
        key("windows.app-overview", "显示当前应用的全部窗口", .windows, 125, control, "打开应用窗口总览；需系统中启用 ⌃↓。", source: missionControl)
        key("windows.desktop-left", "切到左侧桌面", .windows, 123, control, "切换空间；需有相邻桌面并启用系统 ⌃← 快捷键。", recommended: true, source: missionControl)
        key("windows.desktop-right", "切到右侧桌面", .windows, 124, control, "切换空间；需有相邻桌面并启用系统 ⌃→ 快捷键。", recommended: true, source: missionControl)
        key("windows.fullscreen", "进入或退出全屏", .windows, 3, control | cmd, "当前应用需支持全屏；部分网页应用可能另有绑定。", recommended: true)
        key("windows.minimize", "最小化当前窗口", .windows, 46)
        key("windows.hide", "隐藏当前应用", .windows, 4)
        key("windows.hide-others", "隐藏其他应用", .windows, 4, option | cmd)
        key("windows.close", "关闭当前窗口或标签页", .windows, 13, cmd, "可能关闭正在编辑的内容；有未保存内容时由目标应用处理。")
        key("editing.copy", "复制", .editing, 8, cmd, "复制已选中的文字或项目。", recommended: true)
        key("editing.paste", "粘贴", .editing, 9, cmd, "把剪贴板内容放入当前编辑位置。", recommended: true)
        key("editing.cut", "剪切", .editing, 7, cmd, "用于可编辑文字或对象；访达移动文件请选“移动已复制文件”。")
        key("editing.plain-paste", "粘贴并匹配样式", .editing, 9, option | shift | cmd, "适用于支持此命令的 Mac 文本编辑器；Chrome 纯文本粘贴另列。", recommended: true)
        key("editing.undo", "撤销", .editing, 6, cmd, "撤销当前应用上一步操作。", recommended: true)
        key("editing.redo", "重做", .editing, 6, shift | cmd)
        key("editing.select-all", "全选", .editing, 0)
        key("editing.save", "保存文稿", .editing, 1, cmd, "保存当前文稿；网页编辑器的行为由网站决定。", recommended: true)
        key("editing.find", "查找", .editing, 3, cmd, "在当前文稿或页面内查找。", recommended: true)
        key("editing.find-next", "查找下一个", .editing, 5)
        key("editing.find-previous", "查找上一个", .editing, 5, shift | cmd)
        key("editing.bold", "加粗", .editing, 11, cmd, "适用于支持格式编辑的文稿；其他应用可能占用此快捷键。")
        key("editing.italic", "斜体", .editing, 34, cmd, "适用于支持格式编辑的文稿。")
        key("editing.underline", "下划线", .editing, 32, cmd, "适用于支持格式编辑的文稿。")
        key("editing.delete-word", "删除前一个词", .editing, 51, option, "在可编辑文本中删除；分词方式由输入法和应用决定。")
        key("editing.delete-line", "删除至行首", .editing, 51, cmd, "适用于支持 macOS 文本编辑快捷键的输入框。")
        key("editing.forward-delete", "向后删除一个字符", .editing, 117, 0, "删除光标右侧字符。")
        key("editing.emoji", "表情与符号", .editing, 49, control | cmd, "打开系统字符检视器。")
        key("browser.new-tab", "新建标签页", .browser, 17, cmd, "Safari、Chrome 等浏览器。", recommended: true, source: chrome)
        key("browser.reopen-tab", "恢复刚关闭的标签页", .browser, 17, shift | cmd, "Safari、Chrome；具体可恢复范围由浏览器决定。", recommended: true, source: chrome)
        key("browser.next-tab", "下一个标签页", .browser, 48, control, "Safari、Chrome。", recommended: true, source: safari)
        key("browser.previous-tab", "上一个标签页", .browser, 48, control | shift, "Safari、Chrome。", recommended: true, source: safari)
        key("browser.address", "定位地址栏", .browser, 37, cmd, "Safari、Chrome：输入网址或搜索词。", recommended: true, source: chrome)
        key("browser.back", "浏览器后退", .browser, 33, cmd, "Safari、Chrome；需有上一页。", source: chrome)
        key("browser.forward", "浏览器前进", .browser, 30, cmd, "Safari、Chrome；需有前进历史。", source: chrome)
        key("browser.reload", "刷新页面", .browser, 15, cmd, "Safari、Chrome；表单页面可能提示重新提交。", source: chrome)
        key("browser.zoom-in", "放大网页", .browser, 24, cmd, "Safari、Chrome；使用标准键盘布局的 ⌘=。", source: chrome)
        key("browser.zoom-out", "缩小网页", .browser, 27, cmd, "Safari、Chrome。", source: chrome)
        key("browser.zoom-reset", "恢复网页原始大小", .browser, 29, cmd, "Safari、Chrome。", source: chrome)
        key("browser.first-tab", "切到第一个标签页", .browser, 18, cmd, "Safari、Chrome；Safari 需启用用 ⌘1–9 切换标签页。", source: safari)
        key("browser.last-tab", "切到最后一个标签页", .browser, 25, cmd, "Safari、Chrome；Safari 需启用用 ⌘1–9 切换标签页。", source: chrome)
        key("browser.bookmark", "收藏当前网页", .browser, 2, cmd, "Safari、Chrome：打开添加书签界面。", source: chrome)
        key("browser.chrome-plain-paste", "Chrome 粘贴纯文本", .browser, 9, shift | cmd, "Chrome 的可编辑文本框；请勿把它当作所有 Mac 应用的通用粘贴键。", source: chrome)
        key("browser.chrome-downloads", "Chrome 下载列表", .browser, 38, shift | cmd, "仅 Chrome；Safari 下载列表使用另一组合。", source: chrome)
        key("browser.safari-downloads", "Safari 下载列表", .browser, 37, option | cmd, "仅 Safari。", source: safari)
        key("finder.new-window", "新建访达窗口", .finder, 45, cmd, "访达在前台时生效；也可选择直接打开访达。")
        key("finder.new-folder", "新建文件夹", .finder, 45, shift | cmd, "访达在前台时，在当前位置创建文件夹。")
        key("finder.quick-look", "快速预览文件", .finder, 49, 0, "访达已选中文件时生效；在输入框中会输入空格。", recommended: true)
        key("finder.info", "显示文件简介", .finder, 34, cmd, "访达已选中文件时生效。")
        key("finder.duplicate", "制作文件副本", .finder, 2, cmd, "仅访达：复制当前选中文件。")
        key("finder.move-paste", "移动已复制文件", .finder, 9, option | cmd, "先在访达复制文件，再在目标文件夹执行。")
        key("finder.go-folder", "前往指定文件夹", .finder, 5, shift | cmd, "访达在前台时打开路径输入框。")
        key("finder.downloads", "打开下载文件夹", .finder, 37, option | cmd, "仅访达；Safari 的同一组合是下载列表。")
        key("finder.desktop", "打开桌面文件夹", .finder, 2, shift | cmd, "访达在前台时生效。")
        key("finder.home", "打开个人文件夹", .finder, 4, shift | cmd, "访达在前台时生效。")
        key("finder.documents", "打开文稿文件夹", .finder, 31, shift | cmd, "访达在前台时生效。")
        key("finder.parent", "前往上一级文件夹", .finder, 126, cmd, "访达在前台时生效。")
        key("finder.open", "打开选中文件", .finder, 125, cmd, "访达已选中文件或文件夹时生效。")
        key("finder.hidden", "显示或隐藏隐藏文件", .finder, 47, shift | cmd, "访达或支持的文件选择窗口。")
        key("finder.list", "访达列表视图", .finder, 19, cmd, "仅访达。")
        key("finder.columns", "访达分栏视图", .finder, 20, cmd, "仅访达。")
        key("navigation.page-up", "向上翻页", .navigation, 116, 0, "当前阅读区域需支持 Page Up。")
        key("navigation.page-down", "向下翻页", .navigation, 121, 0, "当前阅读区域需支持 Page Down。", recommended: true)
        key("navigation.start", "文稿开头", .navigation, 126, cmd, "可编辑文本中移动到开头；浏览器中可能滚动到页首。")
        key("navigation.end", "文稿末尾", .navigation, 125, cmd, "可编辑文本中移动到末尾；浏览器中可能滚动到页尾。")
        key("navigation.line-start", "光标移到行首", .navigation, 123, cmd, "适用于 Mac 文本编辑器；浏览器可能后退，请在文本框内使用。")
        key("navigation.line-end", "光标移到行尾", .navigation, 124, cmd, "适用于 Mac 文本编辑器。")
        key("navigation.word-left", "光标向前移动一个词", .navigation, 123, option, "在可编辑文本内使用。")
        key("navigation.word-right", "光标向后移动一个词", .navigation, 124, option, "在可编辑文本内使用。")
        key("navigation.select-line-start", "选中至行首", .navigation, 123, shift | cmd, "在可编辑文本内使用。")
        key("navigation.select-line-end", "选中至行尾", .navigation, 124, shift | cmd, "在可编辑文本内使用。")
        key("screenshots.region", "选择区域截图", .screenshots, 21, shift | cmd, "打开区域选择；随后由你选取范围。", recommended: true)
        key("screenshots.clipboard", "区域截图到剪贴板", .screenshots, 21, control | shift | cmd, "选取区域后复制截图，随后可粘贴。", recommended: true)
        key("screenshots.full", "整个屏幕截图", .screenshots, 20, shift | cmd, "立即截取整个屏幕；保存位置按系统截图设置。")
        key("screenshots.toolbar", "截图与录屏工具栏", .screenshots, 23, shift | cmd, "打开系统工具栏，选择截图或录屏；不会直接开始录屏。")
        key("system.spotlight", "打开聚焦搜索", .system, 49, cmd, "使用系统默认 ⌘空格；如已分配给输入法，请用应用启动动作。", recommended: true)
        key("system.input-next", "切换下一个输入法", .system, 49, control | option, "使用 macOS 默认组合；已修改时请录制你的组合。")
        key("system.input-previous", "切回上一个输入法", .system, 49, control, "使用 macOS 默认组合；也可按名称选择已启用输入法。")
        key("system.settings", "打开当前应用设置", .system, 43)
        key("system.dock", "显示或隐藏程序坞", .system, 2, option | cmd)
        key("system.lock", "锁定屏幕", .system, 12, control | cmd, "立即锁定 Mac；不会退出登录或关闭文稿。")
        func action(_ id: String, _ title: String, _ kind: ActionKind, _ detail: String, recommended: Bool = false) {
            values.append(ActionPreset(id: id, title: title, detail: detail, category: .controls,
                recommended: recommended, step: WorkflowStep(kind: kind)))
        }
        action("controls.volume-up", "调高电脑音量", .volumeUp, "控制当前系统输出；不支持软件音量的输出设备会显示错误。")
        action("controls.volume-down", "调低电脑音量", .volumeDown, "控制当前系统输出；执行后回读音量。")
        action("controls.mute", "电脑静音或取消静音", .toggleMute, "控制扬声器输出，不是会议麦克风静音。")
        action("controls.scroll-up", "向上滚动", .scrollUp, "默认每格3行，选用后可调整为1–50行。", recommended: true)
        action("controls.scroll-down", "向下滚动", .scrollDown, "默认每格3行，选用后可调整为1–50行。", recommended: true)
        let apps: [(String, String)] = [
            ("com.apple.finder", "访达"), ("com.apple.Safari", "Safari"), ("com.google.Chrome", "Chrome"),
            ("com.openai.codex", "Codex"), ("com.openai.chat", "ChatGPT"), ("com.anthropic.claudefordesktop", "Claude"),
            ("com.electron.lark", "飞书"), ("com.microsoft.Excel", "Excel"), ("com.microsoft.Word", "Word"),
            ("com.microsoft.Powerpoint", "PowerPoint"), ("com.microsoft.VSCode", "Visual Studio Code"),
            ("com.apple.Notes", "备忘录"), ("com.apple.iCal", "日历"), ("com.apple.Preview", "预览"),
            ("com.apple.Terminal", "终端"), ("com.apple.systempreferences", "系统设置")
        ]
        for (bundle, name) in apps {
            values.append(ActionPreset(id: "apps." + bundle, title: "打开或切换到" + name,
                detail: "直接激活指定应用；未运行时会启动。多窗口应用由系统选择其前台窗口。",
                category: .applications, recommended: ["com.apple.finder", "com.google.Chrome", "com.openai.codex", "com.electron.lark"].contains(bundle),
                step: WorkflowStep(kind: .openApp, argument: bundle)))
        }
        return values
    }()
}
