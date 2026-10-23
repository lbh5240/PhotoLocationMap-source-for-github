# 实际验证结果

2026-10-23，本地 Windows Swift 6.2 与云端 Xcode 27.1 / iOS 27.1 SDK，Swift 6 language mode。

| 检查 | 结果 | 证据范围 |
|---|---|---|
| ZoraCore 生产源码编译与链接 | 通过 | Windows Swift 核心模块，不含 Apple UI/Network 实现 |
| XCTest | 共 53 项，52 通过，1 跳过，0 失败 | 新增14项USB/扩展控制；保留9 BLE、4影像、1 HTTP夹具、10 PTP、4相机会话、11存储/签名/队列（含跳过项） |
| HTTPS 服务实测 | 跳过 | 未设置 ZORA_TEST_HTTPS，没有 NAS 或受信任测试 TLS 服务 |
| Swift iOS 源码语法解析 | 通过 | 仅 parser；不代表 iOS SDK 类型检查、链接或运行通过 |
| Xcode 工程静态检查 | 通过 | 文件引用存在、对象引用解析、XML/plist 合法、生成脚本可重复 |
| iOS 真机 Release 归档 / IPA | 云端通过 | Xcode 27.1、iOS 27.1 SDK，0.3.0 ARM64 iPhoneOS 二进制；未签名，最低 iOS 27.0 |
| iOS 模拟器构建 / UI 测试 | 构建通过；UI 三项通过 | 最终源码875d3de；断开时无假取景、连接页面、照片库/风格、USB模拟器拒绝伪连接；不替代真机验证 |
| Z7 II / BLE Nikon 配对 / 实时图传 | 未验证 | 无连接相机；Synthetic fixtures 不是互通证明 |
| WebDAV / S3 真机 NAS | 未验证 | 没有实际目的地凭据；HTTP 夹具只验证 App 传输调用流程 |

0.3核心云端结果在 `USB_CORE_TEST_RESULTS.txt`；`TEST_RESULTS.txt` 保留0.2历史记录。测试输出时间使用UTC（13:24对应北京时间21:24）。末尾Swift Testing显示0 tests是因为使用XCTest，实际53项结果见All tests统计。BLE样本来自公开Z50 II向量，不代表Z7 II硬件验收。

SwiftPM 在 Windows 提示无法建立 `.build/debug` 便捷符号链接（当前账号没有该符号链接权限）；编译、链接、测试均成功，不需要改系统开发者设置。

S3 固定签名向量经独立 Python 标准库 hashlib/hmac 核算；SHA256 使用空串、abc、百万个 a 的公开向量，HMAC 使用 RFC4231 向量。所有测试凭据均为固定测试文本，工程不包含真实账号密钥。

0.3源码 `875d3de453faaf383908af4f6f87883fc589ad7b` 的 [核心与UI执行记录](https://github.com/lbh5240/PhotoLocationMap-source-for-github/actions/runs/39960752781)、[IPA构建](https://github.com/lbh5240/PhotoLocationMap-source-for-github/actions/runs/39960752899)。本地46个工程/源码文件经UTF-8换行规范化后与云端构建Git blob全部一致。USB_UI_TEST_RESULTS.txt为0.3界面证据，UI_TEST_RESULTS.txt保留0.2历史记录。
