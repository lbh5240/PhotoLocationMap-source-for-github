# ZORA Camera 开发报告

日期：2026-10-22（Asia/Shanghai）。本报告区分源码完成、自动测试和硬件验证。

后续更新：已接入用户提供的 GitHub 仓库，成功通过 Xcode 27 真机 Release 归档并生成未签名 IPA。详见 `IPA_DELIVERY.md`；下文的本地环境描述保留为最初 Windows 开发阶段记录，已不代表当前完全没有 iOS 编译证据。

## 交付物

原生 iOS 27 / Swift 6 / SwiftUI 项目，Xcode 工程与共享 scheme，可独立构建的 ZoraCore Swift 包，五个主要页面、相机 TCP 传输适配、照片库/编辑/导出、独立 Recipes/LUT、WebDAV/S3 传输与持久离线队列，核心/协议夹具/UI 测试、CI 定义、示例及验收清单。没有交付签名 IPA 或声称 App Store 可发布。

## 环境与上下文

- 执行环境为 Windows，具备 Visual Studio C++ 工具链/Windows SDK，无 Mac、Xcode、iOS Simulator、已连接相机或 NAS。
- 原先没有 Swift 编译器。为了运行真实核心测试，从 swift.org 下载 Swift 6.2 官方 Windows 安装包，检查 Apple Inc. Authenticode 签名有效后提取至 workspace/work。没有全局安装 Swift 或修改系统 PATH；长路径通过本次任务的临时 W: 映射解决。
- `read_thread` 已读取引用对话，但助手方案正文仅为 `chatgpt-content-reference` 占位符，无法读取。此实现采用用户本次明确的 ZORA 任务书，不宣称完整恢复了旧方案。
- 当前模型/Work 模式无法由本任务工具切换；已提示用户在可用界面选择 GPT-6.1 Sol / Medium，未虚称配置已经改变。参考 [OpenAI 官方使用建议](https://learn.chatgpt.com/docs/learn/best-practices)。

## 已实现的具体行为

1. 相机：独立 PTP/IP 线格式实现、TCP 分帧、双通道初始化、GetDeviceInfo/OpenSession、只开放设备声明操作、标准快门、Nikon AF、Nikon Live View、属性描述/枚举/范围写入、对象列表与有上限下载。无模拟生产驱动。
2. 监看：相机 JPEG 可解码后才显示画面；网格、亮度直方图、梯度峰值和 RGB 高亮斑马纹。处理 actor 与逐帧背压，停止时等待当前帧。
3. 资料库：Files 多选导入、UUID 命名、原子 JSON、原片保留、文件搜索、Core Image 非破坏处理、sRGB JPEG 导出/分享、Recipe 持久化。
4. 风格：三个原创 Recipes、参数编辑、JSON 导入、2–64 阶标准域 `.cube` 校验和应用。没有云创身份、私有 API 或官方配方转换。
5. NAS：HTTPS WebDAV PUT、S3 SigV4 PUT、自带 SHA256/HMAC、钥匙串凭据、独立目的地快照、稳定 object key、2xx 成功确认、原子队列、重启恢复、离线保留、8 次尝试上限、退避与受阻重试、拒绝 HTTP 重定向。
6. 工程：现成 `.xcodeproj`，可重复生成脚本，隐私用途说明、Hotspot entitlement、初始隐私清单、核心/原生 UI 测试、macOS CI。

## 测试证据

实际执行结果见 `TEST_RESULTS.txt`；报告中不把“有测试文件”写成“测试已通过”。Swift 核心测试会实际编译生产代码；协议和 HTTP 测试明确使用 synthetic fixtures。iOS 文件可在 Windows 做 Swift 语法解析，但未做 Apple SDK 类型检查、链接、运行或 UI 截图验证。

首轮编译捕获了 CameraProperty 初始化闭包过早捕获 self，已修复后重测。Mac 和硬件检查都保留在 `HARDWARE_ACCEPTANCE.md`，不自动勾选。

## 尚未完成及下一阶段

优先拿到 Mac/iOS 27 SDK 构建结果及 Z7 II 固件/网络模式数据；完成 PTP/IP 接受性与 Nikon 私有认证研究。若相机拒绝通用协议，需要合法、可审查的 Nikon 协议或 SDK 平台授权后补充适配；当前源码不会将失败变为模拟成功。

随后落实大文件分块下载/流式摘要/S3 multipart、后台 URLSession 与 BGTaskScheduler、远端校验、事件照片同步、更多相机控制、视频/触摸对焦/拍摄计划、NAS 配置删除/队列清理、文件保护与恢复策略，以及真机性能和可访问性验收。机内云创功能不能靠 App 绕过硬件/固件兼容性，继续采用独立手机端处理路线。

当前完成的是可继续开发并可独立测试的实验工程；完整替代 SnapBridge、所有遥控功能和生产上线验收尚未完成。
