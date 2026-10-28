# IPA 构建交付记录

2026-10-28 21:33（Asia/Shanghai），云端 Xcode 27.1 / iOS 27.1 SDK 成功编译、链接并归档 0.4.0 ARM64 真机版本。

- 文件：`ZORACamera-0.4-unsigned.ipa`，同时更新通用文件名，保留旧版本文件。
- 版本：0.4.0 / build 4 / Bundle ID `app.zora.camera`
- 最低系统：iOS 27.0；ARM64；平台 iPhoneOS
- 大小：531700 字节；主可执行文件 1359736 字节
- SHA256：`25e8c468034d737110d5371aae52a63e143385189439e792fbf8433e9e82ce17`
- 未签名，signature_verified=false；需要有效签名及匹配描述文件后安装，热点 entitlement 也需匹配。
- 最终相机代码：`0047a30747466e27f09bdb3b9ae004148ead832a`
- [成功的 IPA 构建](https://github.com/lbh5240/PhotoLocationMap-source-for-github/actions/runs/40697335039)
- [云端原始产物](https://github.com/lbh5240/PhotoLocationMap-source-for-github/actions/runs/40697335039/artifacts/12819259248)（默认保留14天）
- 外层 artifact SHA256：`cd6f64d14b5fae60e427389537bcb81948d19a9a8fafdb8a32517f6c2243606f`

下载后核对外层 ZIP 与内部 IPA 哈希，解析 Payload、Info.plist、Mach-O ARM64 与 LC_BUILD_VERSION 设备标识，确认版本及 build number。三项中文权限用途与本地 plist 逐字相同；48 份工程/源码文件与最终云端 Git blob 一致（UTF-8/LF）。这些检查不证明 Apple 签名或硬件联通。

核心 XCTest 68 项：67 通过、1 个真实 HTTPS 服务测试未配置明确跳过、0 失败。打包检查 macOS 5 通过、1 个非 Mac 条件用例跳过；本地 Windows 6 项全部通过。模拟器 UI 单独记录于 TEST_SUMMARY.md。

本版重点是配对码确认后的注册和系统配对恢复，详见 PAIRING_FLOW_REPAIR.md；保留 USB/公开协议、照片/独立滤镜与 NAS 队列。没有 iPhone/Z7 II/NAS 实机验收，不能将 CI 通过写成用户机身故障已解决。

源码包 `ZORACamera-0.4-source.zip` 含工程、测试、许可证、报告和验收清单。SOURCE_SHA256.json 记录实际交付内容哈希，自身不参与哈希。用同 Bundle ID、同一签名来源覆盖安装，才能尽可能沿用 App 与钥匙串资料；不要先删除旧 App 或反复重置相机绑定。
