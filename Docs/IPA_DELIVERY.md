# IPA 构建交付记录

2026-10-22 11:55（Asia/Shanghai），云端 Xcode 27.0 / iOS 27.0 SDK 已成功编译、链接并归档 ARM64 真机版本。

- 文件：`ZORACamera-unsigned.ipa`
- 版本：0.1.0 / Bundle ID `app.zora.camera`
- 最低系统：iOS 27.0，架构 ARM64，平台 iPhoneOS
- 大小：314610 字节；主可执行文件 808680 字节
- SHA256：`2b6e1675ff5cb574dc08d47da36d0e5303b0db312b2585602f01e2f98c8952ac`
- 签名：未签名，`signature_verified=false`，需要匹配的签名与描述文件后安装
- 构建源码提交：`75bb48482f4bea4700d3875633ec5213a9059faa`
- [成功的 IPA 构建](https://github.com/lbh5240/PhotoLocationMap-source-for-github/actions/runs/39719265363)
- [GitHub 构建产物](https://github.com/lbh5240/PhotoLocationMap-source-for-github/actions/runs/39719265363/artifacts/12400342702)（默认保留14天）

下载后已再次核对外层 artifact 哈希与内部 IPA 报告哈希，并解析 Payload、Info.plist、Mach-O ARM64 与 LC_BUILD_VERSION 的 iOS 设备标识。没有将源码包或模拟器 App 当成 IPA。

云端核心 XCTest 共30项，29通过、1个真实 HTTPS 服务测试明确跳过、0失败。打包检查在 macOS 上5通过，非Mac环境检查按设计跳过。iOS Debug 模拟器构建通过；自动界面测试另见最新 CI 结果，不以归档成功替代 UI 或硬件验证。

为通过真实 Xcode 构建，已修复 Core Image 矩形尺寸类型、SwiftUI 自定义颜色推导和带 footer 的 Section 初始化；CI 明确选择 ARM64 模拟器架构，避免静态包的跨架构产物混用。

本次未提供 Apple 签名材料，没有运行签名安装、iPhone/Z7 II/NAS 实机联调。签名服务若不支持 Hotspot Configuration，App 内自动加入 Wi-Fi 能力也可能不可用。实验协议与未完成功能的限制继续以 README 和通信矩阵为准。
