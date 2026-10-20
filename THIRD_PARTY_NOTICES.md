# Third-party notices / 第三方说明

VIBEKEY is an independent macOS application for interoperability with AU05 hardware. It uses Apple's system frameworks, including SwiftUI, AppKit, IOKit, Carbon, CoreAudio and UserNotifications. No external Swift package is required by this source distribution.

The AU05 protocol implementation is independently written project code. This repository does not contain manufacturer application binaries, firmware, extracted product photographs, commercial application source, speech engines, language models, or input-method engines. The device illustration is an original SwiftUI schematic in `Sources/Vibekey/Support/DeviceProductArtwork.swift`.

The VIBEKEY application icon is rendered by the project's original Swift/AppKit vector implementation in `Sources/Vibekey/Support/VibekeyBrand.swift`. An eight-circle geometry inspired its design. The icon is project identity artwork and is not an official logo of a hardware manufacturer. The MIT license does not grant rights to third-party trademarks or imply endorsement by Apple, Ulanzi, OpenAI, Anthropic or any hardware vendor. Those names identify platforms or interoperable products only.

The optional Agent bridge accepts supported hook event metadata; it does not bundle the agents themselves. Compatibility depends on the installed agent version and its supported hook contracts.

---

VIBEKEY 是独立开发的 macOS AU05 配套应用，使用 Apple 系统框架，无外部 Swift 包依赖。AU05 协议实现为本项目独立编写的互操作代码；仓库不分发原厂程序、固件、提取的产品照片、商业软件源码、语音引擎、模型或输入法引擎。设备插图由项目自己的 SwiftUI 代码绘制。

App 图标由项目 Swift/AppKit 矢量实现生成，用于标识本项目。MIT 许可不授予第三方商标权，也不表示硬件厂商、Apple、OpenAI 或 Anthropic 对本项目的认可或背书。Agent 桥接只处理受支持的事件元数据，不分发 Agent 软件本身。
