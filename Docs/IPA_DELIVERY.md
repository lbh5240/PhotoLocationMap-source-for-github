# IPA 构建交付记录

2026-10-23 20:48（Asia/Shanghai），云端 Xcode 27.1 / iOS 27.1 SDK 成功编译、链接并归档 0.2.0 ARM64 真机版本。

- 文件：`ZORACamera-0.2-unsigned.ipa`（同时更新通用文件名 `ZORACamera-unsigned.ipa`）
- 版本：0.2.0 / build 2 / Bundle ID `app.zora.camera`
- 最低系统：iOS 27.0，架构 ARM64，平台 iPhoneOS
- 大小：409965 字节；主可执行文件 1051696 字节
- SHA256：`fc309a355dacb26a7345970a08bf0fa6b9dc45eed8f83f5a06541db0a00f27de`
- 签名：未签名，`signature_verified=false`，需要有效签名及匹配描述文件后安装
- 最终相机代码提交：`6e89dfa377d577faccbab063580186e7302d5fa8`
- [成功的 IPA 构建](https://github.com/lbh5240/PhotoLocationMap-source-for-github/actions/runs/39955966574)
- [GitHub 构建产物](https://github.com/lbh5240/PhotoLocationMap-source-for-github/actions/runs/39955966574/artifacts/12502831207)（默认保留14天）
- 外层 artifact SHA256：`f0970434b7f8b3bbadf79e1e82a8a59f5674813405f39da8a1e1e29ad5b2fcf5`

已再次核对外层 ZIP 与内部 IPA 哈希，并解析 Payload、Info.plist、Mach-O ARM64 与 LC_BUILD_VERSION 的 iOS 设备平台标识。另确认 MIT 许可证随 App bundle 打包、版本 0.2.0、后台 bluetooth-central 声明存在。

云端核心 XCTest 39 项：38 通过、1 个真实 HTTPS 服务测试因没有配置明确跳过、0 失败。打包检查 macOS 5 通过、非 Mac 检查跳过；Windows 6 项全部通过。模拟器构建与 UI 执行结果见 `TEST_SUMMARY.md`。

本版增加的蓝牙认证、Wi-Fi 唤醒和自动连接链路见 `BLUETOOTH_AND_WAKE.md`。没有 Apple 签名材料，没有运行 iPhone/Z7 II/NAS 实机联调；系统配对、Hotspot entitlement、休眠/关机唤醒和电量/校时仍需真机验收。

源码 ZIP 包含工程、测试、许可证、研究报告和验收清单。`Docs/SOURCE_SHA256.json` 记录交付源码内容哈希，自身不参与哈希。
