# 实际验证结果

2026-10-28，ZORA 0.4.0。最终相机代码 `0047a30747466e27f09bdb3b9ae004148ead832a`，云端 Xcode 27.1 / iOS 27.1 SDK，Swift 6 language mode。

| 检查 | 结果 | 证据范围 |
|---|---|---|
| ZoraCore 编译、链接与 XCTest | 68 项，67 通过、1 跳过、0 失败 | 包含新增 15 项注册/写入顺序/回调竞态；协议传输为明确夹具 |
| 真实 HTTPS 测试 | 明确跳过 | 未设置 ZORA_TEST_HTTPS，没有实际 NAS 凭据 |
| Windows Swift 6.2 | 同为 68 项，67 通过、1 跳过、0 失败 | 核心模块，不包含 Apple 平台层 |
| IPA 打包检查 | Windows 6 通过；macOS 5 通过、1 平台条件跳过 | 拒绝模拟器、伪装源码、截断 Mach-O，不证明 Apple 签名 |
| iOS 平台编译 | 模拟器与真机均通过 | 实际 Apple SDK 类型检查、链接 |
| ARM64 真机 Release / IPA | 归档、打包通过 | 0.4.0 / build 4，未签名，最低 iOS 27.0 |
| iOS 原生界面测试 | 3 项全部通过 | 无相机时无假取景、配对步骤与连接页、照片/风格导航、USB 模拟器明确拒绝；不替代真机验收 |
| 源码上传完整性 | 48 份源码/工程文件全部匹配 | 本地 UTF-8/LF 规范化后 Git blob SHA-1 对比，无乱码差异 |
| Z7 II / iPhone 配对、USB、图传 | 未验证 | 无连接硬件，不能声称实际故障已经排除 |
| NAS、RAW、性能与后台 | 未真机验收 | 实际受信任 HTTPS、NEF、相机模式与系统调度待测 |

[核心与 UI 执行](https://github.com/lbh5240/PhotoLocationMap-source-for-github/actions/runs/40697335292)；[IPA 构建](https://github.com/lbh5240/PhotoLocationMap-source-for-github/actions/runs/40697335039)。核心原始摘录在 PAIRING_CORE_TEST_RESULTS.txt，本次 UI 另存 PAIRING_UI_TEST_RESULTS.txt。构建产物和 SHA256 见 IPA_DELIVERY.md。

新增测试直接调用生产注册状态机与 NikonRegistrationExchange，应答失败后不确认就绪、不发送 Wi-Fi；时间、连接请求及 GPS 保留分别断言。不创建模拟相机生产路径。旧 Blowfish/Z50 II 样本继续通过，只证明算法一致，不是 Z7 II 互操作证据。测试凭据都是固定测试文本。

首轮云端编译发现 @Observable 不支持一条声明中的多个存储变量，已拆分并完整重建，交付使用上述最终提交。最终提交的首轮 UI 执行在模拟器 bootstatus 180 秒超时，尚未执行 App 测试；同一提交重试第 2 次成功，核心与 UI 均通过。旧 TEST_RESULTS.txt / UI_TEST_RESULTS.txt / USB_* 保留为历史记录。时间戳使用 UTC（13:33 对应北京时间 21:33）。

没有 Apple 签名材料、已安装真机或机身屏幕观测。硬件回归步骤在 PAIRING_FLOW_REPAIR.md，未执行项保留在 HARDWARE_ACCEPTANCE.md。
