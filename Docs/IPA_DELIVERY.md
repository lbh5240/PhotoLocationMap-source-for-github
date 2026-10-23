# IPA 构建交付记录

2026-10-23 21:24（Asia/Shanghai），云端 Xcode 27.1 / iOS 27.1 SDK 成功编译、链接并归档 0.3.0 ARM64 真机版本。

- 文件：`ZORACamera-0.3-unsigned.ipa`（同时更新通用文件名 `ZORACamera-unsigned.ipa`）
- 版本：0.3.0 / build 3 / Bundle ID `app.zora.camera`
- 最低系统：iOS 27.0，架构 ARM64，平台 iPhoneOS
- 大小：495574 字节；主可执行文件 1273824 字节
- SHA256：`c519f2b201f0c6dfcfb80f4ed6c2ef41bcce9d468b19b0bb9031eeefbf3e31b8`
- 签名：未签名，`signature_verified=false`，需要有效签名及匹配描述文件后安装
- 最终相机代码提交：`875d3de453faaf383908af4f6f87883fc589ad7b`
- [成功的 IPA 构建](https://github.com/lbh5240/PhotoLocationMap-source-for-github/actions/runs/39960752899)
- [GitHub 构建产物](https://github.com/lbh5240/PhotoLocationMap-source-for-github/actions/runs/39960752899/artifacts/12504586908)（默认保留14天）
- 外层 artifact SHA256：`4a77986ceb22b98ffbb2748ccd2441c893562bb9507fc1d0dfc59ab019be3597`

已再次核对外层 ZIP 与内部 IPA 哈希，并解析 Payload、Info.plist、Mach-O ARM64 与 LC_BUILD_VERSION 的 iOS 设备平台标识。确认 MIT 许可证、版本0.3.0、USB用途与蓝牙后台声明存在；包内三项中文权限文案与原始源码逐字相同。本地46份工程/源码文件与最终云端源码Git blob一致。

云端核心 XCTest 53 项：52 通过、1 个真实 HTTPS 服务测试因没有配置明确跳过、0 失败。打包检查 macOS 5 通过、非 Mac 检查跳过。模拟器构建与 UI 执行结果见 `TEST_SUMMARY.md`。

本版增加的 USB 连接与扩展控制见 `USB_AND_PUBLIC_PROTOCOLS.md`，蓝牙链路见 `BLUETOOTH_AND_WAKE.md`。没有 Apple 签名材料，没有运行 iPhone/Z7 II/NAS 实机联调；USB 权限/线材、系统配对、Hotspot entitlement、休眠唤醒、录像与镜头行为仍需真机验收。

源码 ZIP 包含工程、测试、许可证、研究报告和验收清单。`Docs/SOURCE_SHA256.json` 记录交付源码内容哈希，自身不参与哈希。
