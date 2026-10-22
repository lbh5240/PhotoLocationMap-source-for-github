# 实际验证结果

2026-10-22，本地 Windows，Swift 6.2（swift-6.2-RELEASE），Swift 6 language mode。

| 检查 | 结果 | 证据范围 |
|---|---|---|
| ZoraCore 生产源码编译与链接 | 通过 | Windows Swift 核心模块，不含 Apple UI/Network 实现 |
| XCTest | 共 30 项，29 通过，1 跳过，0 失败 | 4 影像算法、1 HTTP 夹具端到端、10 PTP 编解码、4 相机会话夹具、11 存储/签名/队列（含跳过项） |
| HTTPS 服务实测 | 跳过 | 未设置 ZORA_TEST_HTTPS，没有 NAS 或受信任测试 TLS 服务 |
| Swift iOS 源码语法解析 | 通过 | 仅 parser；不代表 iOS SDK 类型检查、链接或运行通过 |
| Xcode 工程静态检查 | 通过 | 文件引用存在、对象引用解析、XML/plist 合法、生成脚本可重复 |
| iOS 构建 / UI 测试 | 未运行 | 无 Mac/Xcode/iOS Simulator |
| Z7 II / BLE Nikon 配对 / 实时图传 | 未验证 | 无连接相机；Synthetic fixtures 不是互通证明 |
| WebDAV / S3 真机 NAS | 未验证 | 没有实际目的地凭据；HTTP 夹具只验证 App 传输调用流程 |

完整终端结果在 `TEST_RESULTS.txt`。测试输出时间使用 XCTest 的 UTC（03:30 对应北京时间11:30）。末尾 Swift Testing 显示 0 tests 是因为本项目采用 XCTest，实际30项结果在此前的 All tests 统计中。

SwiftPM 在 Windows 提示无法建立 `.build/debug` 便捷符号链接（当前账号没有该符号链接权限）；编译、链接、测试均成功，不需要改系统开发者设置。

S3 固定签名向量经独立 Python 标准库 hashlib/hmac 核算；SHA256 使用空串、abc、百万个 a 的公开向量，HMAC 使用 RFC4231 向量。所有测试凭据均为固定测试文本，工程不包含真实账号密钥。
