# ZORA Camera

面向 Nikon Z7 II 的原生 iOS 27 摄影 App 开发工程。Swift 6、SwiftUI、Liquid Glass；独立核心包不依赖 Apple UI 框架。

**这是可继续开发的实验版本，不是已交付验收的 SnapBridge 替代品。** 相机驱动发送实际 PTP/IP 数据，未连接设备时不生成取景画面，也不会显示虚假连接成功。Z7 II 私有认证、相机网络模式及各项操作仍需真机验证。完整状态见 [开发报告](Docs/DEVELOPMENT_REPORT.md) 与 [通信可行性矩阵](Docs/CAMERA_FEASIBILITY.md)。

## 打开与运行

1. 在 Mac 上使用包含 iOS 27 SDK 的 Xcode 打开 `ZORACamera.xcodeproj`。
2. 选择 `ZORACamera` scheme、iPhone/iPad 模拟器或真机。
3. 真机运行时，在 Signing & Capabilities 选择自己的 Apple Developer Team，并使用自己的 Bundle ID。工程包含 Hotspot Configuration entitlement。
4. 运行后可以直接导入照片、编辑与导出、导入 `.cube` 或 Recipe JSON、配置 NAS 和查看上传队列。相机不是这些流程的前置条件。
5. 真实相机连接：在 Z7 II 上启用连接至智能设备的 Wi-Fi → iPhone 加入相机热点 → 在“拍摄 → 连接相机”填写实际相机 IP → 建立实验 PTP/IP 会话。

连接失败时不要将问题解释为权限已经满足或协议已兼容：系统本地网络权限、网络模式、IP、端口、Nikon 私有配对均可能影响结果。不要同时让 SnapBridge 占用相机会话。

## 构建与测试

生成 IPA：参阅 [云端/Mac 打包说明](Docs/IPA_BUILD.md)。仓库新增 `Build ZORA IPA` 工作流，默认生成需后续签名的 ARM64 真机 IPA；须等云端 Xcode 编译成功才会有实际 IPA 文件。

```sh
swift test
python3 Tools/generate_project.py
xcodebuild -project ZORACamera.xcodeproj -scheme ZORACamera \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ZORACamera.xcodeproj -scheme ZORACamera \
  -destination 'platform=iOS Simulator,name=<已安装的模拟器名称>' test
```

`swift test` 运行核心单元测试及显式协议夹具测试。`UITests/` 需要 Xcode/iOS 模拟器；可选真实 HTTPS 测试通过 `ZORA_TEST_HTTPS` 指向你控制并配置有效证书的测试服务，默认跳过。不要把测试夹具当成真实相机通信证据。当前环境的实测记录保存在 `Docs/TEST_RESULTS.txt`。

`Tools/generate_project.py` 可重建已提交的工程和共享 scheme，无需安装 XcodeGen 或第三方依赖。新增 iOS/UITests 源文件后重新运行即可。项目没有外部 Swift 包依赖。

## 可使用的功能路径

- 拍摄：真实 TCP 双通道、PTP/IP 初始化、设备信息/操作集、Session、标准快门、Nikon AF/Live View 操作、标量属性枚举与设置、存储卡前 200 项/存储区、下载。
- 监看：实际 JPEG 解码、九宫格、预览直方图、RGB 高亮斑马纹、亮度梯度峰值辅助。不是 RAW 传感器测量；没有音频、波形、矢量示波器或伪造曝光参数。
- 照片：Files 多选导入、NEF/NRW/DNG 原片保留、持久索引、非破坏编辑、sRGB JPEG 导出、系统分享。RAW 解码失败仍保留原片，并显示具体不可用状态。
- 风格：原创 Recipes、JSON 导入、3D `.cube` 导入、Core Image 曝光/色彩/色温/LUT。不是 Nikon 云创账号集成，不向 Z7 II 写入云创配方。
- NAS：HTTPS WebDAV PUT、S3 SigV4 path-style PUT、钥匙串凭据、原子持久队列、离线保留、重启恢复、去重、指数退避、认证失败受阻、手动重试。

WebDAV 需先创建设置中的远端目录。S3 需先创建 bucket。App 给原片生成固定唯一 key，重试覆盖同一 key；只接受 HTTP 2xx 为服务器成功确认，未做远端内容哈希复核。NAS 配置修改不会重写旧任务目的地。有效证书是必需条件，不提供绕过 TLS 的开关。

## 当前明确边界

- 尚无 Xcode/iOS 构建、设备 UI 截图、安装包、签名或 App Store 验收结果。
- BLE 是真实扫描，Nikon 私有 GATT 配对/唤醒/自动 Wi-Fi 切换未实现。
- 未确认 Z7 II 在智能设备模式接受通用 PTP/IP；拒绝握手会报错，不会降级为模拟成功。需要实际固件、网络模式和授权协议样本。
- 相机单文件下载 64 MiB 上限；更大 NEF 可通过 Files 导入。S3 上传单文件 256 MiB 上限，尚无 multipart/resume。
- 队列在 App 前台/仍获执行时间时工作；未接入后台 URLSession、BGTaskScheduler，不承诺后台持续上传。退到后台会停止实时取景。
- 没有视频录制控制、触摸对焦区域、焦点堆栈、延时/包围拍摄、Bulb、机内删除/格式化、Picture Control 写入、地理标签回写、Nikon ID/云创登录。
- LUT 当前仅存内存，重启后需重新导入。Recipes 和每张照片导出时采用的编辑参数会持久保存。
- 专业监看是可用的基础辅助；无帧率、延迟、耗电、热管理真机性能保证。

## 源码结构

```text
Sources/ZoraCore/   PTP/IP、可注入会话、属性/文件解析、照片库、LUT、监看、SHA256/SigV4、上传队列
iOS/Camera/        Network.framework TCP 传输
iOS/Services/      Core Image、Keychain、CoreBluetooth、Wi-Fi 加入/网络状态
iOS/Views/         五个原生页面与照片编辑器
Tests/             Swift 核心与端到端协议夹具测试
UITests/           原生 UI 冒烟测试
Examples/          原创 Recipe 与 Identity LUT
Docs/              证据、架构、验收和测试记录
```

前一对话方案正文未能通过引用恢复，只有用户需求和占位符可读；本工程依照本次明确任务书实现，没有宣称读取到完整旧方案。
