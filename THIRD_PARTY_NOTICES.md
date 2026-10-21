# Third-party notices / 第三方说明

VIBEKEY is an independent macOS application for interoperability with AU05 hardware. It uses Apple's system frameworks, including SwiftUI, AppKit, IOKit, Carbon, CoreAudio and UserNotifications. Sparkle 2.10.0 is the pinned update framework. Its MIT and bundled third-party notices are retained in `Assets/ThirdParty/Sparkle-LICENSE.txt` and copied into App resources. Official source: https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0 .

The AU05 protocol implementation is independently written project code. This repository does not contain manufacturer application binaries, firmware, extracted product photographs, commercial application source, speech engines, language models, or input-method engines. `Assets/Devices/au05-3d.png` is a complete render of the project's own revision B 3D exterior model, retaining its enclosure, dial, microphone vents and three keys. Proportions are based on public product references; it is illustrative artwork, not engineering CAD. See `Assets/Devices/README.md` for provenance.

The VIBEKEY application icon is rendered by the project's original Swift/AppKit vector implementation in `Sources/Vibekey/Support/VibekeyBrand.swift`. An eight-circle geometry inspired its design. The icon is project identity artwork and is not an official logo of a hardware manufacturer. The MIT license does not grant rights to third-party trademarks or imply endorsement by Apple, Ulanzi, OpenAI, Anthropic or any hardware vendor. Those names identify platforms or interoperable products only.

The optional Agent bridge accepts supported hook event metadata; it does not bundle the agents themselves. Compatibility depends on the installed agent version and its supported hook contracts.

---

VIBEKEY 是独立开发的 macOS AU05 配套应用，使用 Apple 系统框架，并集成固定版本 Sparkle 2.10.0 更新框架，其许可证及第三方说明随源码和 App 保留。AU05 协议实现为本项目独立编写的互操作代码；仓库不分发原厂程序、固件、提取的产品照片、商业软件源码、语音引擎、模型或输入法引擎。设备图来自本项目 revision B 三维外观模型的完整渲染，保留外壳、旋钮、麦克风网孔及三个按键，未替换为简化示意图；比例参考公开产品资料，不属于工程 CAD。

App 图标由项目 Swift/AppKit 矢量实现生成，用于标识本项目。MIT 许可不授予第三方商标权，也不表示硬件厂商、Apple、OpenAI 或 Anthropic 对本项目的认可或背书。Agent 桥接只处理受支持的事件元数据，不分发 Agent 软件本身。
