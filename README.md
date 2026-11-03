# ZORA Camera

当前源码版本 **0.5.0**：新增拍摄后自动导入（Nikon 事件驱动）、触摸对焦（帧头坐标自校验）、延时快门/间隔拍摄/包围曝光/焦点包围、相机端单张删除、断点续传下载、曝光参数可读显示、手机定位地理标签、LUT 库持久化、Recipe 新调色项与自定义保存、照片收藏/评分/删除、WebDAV 自动建目录与上传后大小核对。完整清单见 [0.5 更新说明](Docs/RELEASE_0.5.md)。0.5 代码未在本地编译，需先跑云端 CI。0.4 的配对修复说明见 [配对全流程修复报告](Docs/PAIRING_FLOW_REPAIR.md)、[USB 与公开协议报告](Docs/USB_AND_PUBLIC_PROTOCOLS.md) 和 [IPA 记录](Docs/IPA_DELIVERY.md)。Z7 II 真机互操作尚待验收。

面向 Nikon Z7 II 的原生 iOS 27 摄影 App 开发工程。Swift 6、SwiftUI、Liquid Glass；独立核心包不依赖 Apple UI 框架。

**这是可继续开发的实验版本，不是已交付验收的 SnapBridge 替代品。** 相机驱动发送实际 PTP/IP 数据，未连接设备时不生成取景画面，也不会显示虚假连接成功。Z7 II 私有认证、相机网络模式及各项操作仍需真机验证。完整状态见 [开发报告](Docs/DEVELOPMENT_REPORT.md) 与 [通信可行性矩阵](Docs/CAMERA_FEASIBILITY.md)。

已通过云端 Xcode 27 的 ARM64 真机 Release 归档，并生成未签名 IPA；构建记录和哈希见 [IPA 交付记录](Docs/IPA_DELIVERY.md)。未签名包需要签名后才能安装。

## 打开与运行

1. 在 Mac 上使用包含 iOS 27 SDK 的 Xcode 打开 `ZORACamera.xcodeproj`。
2. 选择 `ZORACamera` scheme、iPhone/iPad 模拟器或真机。
3. 真机运行时，在 Signing & Capabilities 选择自己的 Apple Developer Team，并使用自己的 Bundle ID。工程包含 Hotspot Configuration entitlement。
4. 运行后可以直接导入照片、编辑与导出、导入 `.cube` 或 Recipe JSON、配置 NAS 和查看上传队列。相机不是这些流程的前置条件。
5. 真实相机连接：在“拍摄 → 连接相机”搜索 Nikon → 两端确认配对提示 → 等待相机注册验证完成 → 首次保存相机热点信息 → 点击“唤醒并连接相机”。已在旧版确认过配对码但未完成时，先点“继续验证未完成的相机配对”；如仍提示未完成，点“继续系统配对并重新验证”。覆盖安装时保留原身份，勿反复遗忘或重置相机。也保留手动加入 Wi-Fi / 填写相机 IP 的路径，详见修复报告。
6. USB：在“连接相机”选择“USB 有线”，接入数据线、开启相机、搜索并允许系统媒体/控制权限，再选择相机。取景被拒时可按机身状态主动接管控制；完成后释放控制。

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

`swift test` 运行核心单元测试及显式协议夹具测试。`UITests/` 需要 Xcode/iOS 模拟器；可选真实 HTTPS 测试通过 `ZORA_TEST_HTTPS` 指向你控制并配置有效证书的测试服务，默认跳过。不要把测试夹具当成真实相机通信证据。0.4 的实测记录保存在 `Docs/TEST_RESULTS.txt`；0.5 新增 `Tests/ZoraCoreTests/FeatureTests.swift`（16 项），尚未执行。

`Tools/generate_project.py` 可重建已提交的工程和共享 scheme，无需安装 XcodeGen 或第三方依赖。新增 iOS/UITests 源文件后重新运行即可。项目没有外部 Swift 包依赖。

## 可使用的功能路径

- 拍摄：USB 系统会话 / TCP 双通道，真实 PTP、能力门禁、标准/落卡快门、AF/Live View、触摸对焦（9205，帧头校验通过才开放）、录像启停、近远手动调焦、远程控制接管/释放、终止连拍/长曝、曝光参数以 f/、1/250、±EV、ISO 等可读形式显示与选择、取景信息条。
- 拍摄工具：手机计时延时快门、间隔拍摄（按绝对时间槽，超时跳过不补拍）、包围曝光（只用相机声明的曝光补偿/快门/ISO 值，拍完恢复）、焦点包围（9204 步进 + 90C8 就绪）。均可在指令之间取消。
- 相机文件：多卡容量与可拍张数、分页浏览、筛选、拍摄时间、真实缩略图、101B 分块下载、中断后续传、单文件下载进度、批量导入未导入照片、确认后单张删除（100B）、已导入标记。
- 自动传输：依据 ObjectAdded 事件（PTP/IP 事件通道、USB 事件或 Nikon 90C7 CheckEvent 轮询）自动导入新拍摄，可选包含 RAW、可选自动加入 NAS 队列；按对象稳定标识去重。
- 连接：原生 Nikon BLE 四阶段认证、独立相机注册状态、校时/连接建立请求应答、系统配对释放与重连验证、未完成身份续配、身份/热点钥匙串保存、Wi-Fi 唤醒、已验证相机最多五次退避重连、系统蓝牙恢复、前台自动进入 PTP、校时与电量、持久分阶段诊断。
- 监看：实际 JPEG 解码、九宫格、预览直方图、RGB 高亮斑马纹、亮度梯度峰值辅助。不是 RAW 传感器测量；没有音频、波形、矢量示波器或伪造曝光参数。
- 照片：Files 多选导入、NEF/NRW/DNG/HEIF 原片保留、持久索引、收藏/五星评分/筛选、删除、手机定位地理标签、非破坏编辑、保留 EXIF 并修正方向的 sRGB JPEG 导出、系统分享。
- 风格：7 个原创 Recipes（新增清冷胶片、暖调人像、高反差街拍、柔和褪色）、编辑器“保存为新风格”、导出/删除 Recipe JSON、色调/高光恢复/阴影/自然饱和/暗角/颗粒、持久化 LUT 库。不是 Nikon 云创账号集成，不向 Z7 II 写入云创配方。
- NAS：HTTPS WebDAV PUT（缺目录自动 MKCOL）、S3 SigV4 path-style PUT、上传后 HEAD 核对大小、钥匙串凭据、原子持久队列、离线保留、重启恢复、去重、指数退避、认证失败受阻、手动重试、清除/移除任务。

S3 需先创建 bucket。App 给原片生成固定唯一 key，重试覆盖同一 key；HTTP 2xx 后再以 HEAD 的 Content-Length 核对大小，不一致会重新上传；服务器不支持 HEAD 时标记“未核对”。未做远端内容哈希复核。NAS 配置修改不会重写旧任务目的地。有效证书是必需条件，不提供绕过 TLS 的开关。

## 当前明确边界

- 已完成云端 Xcode/iOS 真机归档与未签名 IPA 打包；尚无签名安装、真实设备 UI 截图或 App Store 验收结果。
- BLE GATT 认证、唤醒及自动 Wi-Fi 衔接已实现；公开跨机型向量测试通过，Z7 II 首配/系统绑定/唤醒仍待硬件验收。iOS 加入网络可能需要用户确认，后台与强制退出时不保证唤醒。
- 未确认 Z7 II 在智能设备模式接受通用 PTP/IP；拒绝握手会报错，不会降级为模拟成功。需要实际固件、网络模式和授权协议样本。
- 声明 101B 的相机采用最大4MiB分块，支持超过64MiB的普通RAW，中断后按对象标识续传；64位大小/偏移的扩展对象（≥4 GiB 视频）未实现。无分块能力时仍限制64MiB。S3 上传单文件256MiB上限，尚无 multipart。
- 队列在 App 前台/仍获执行时间时工作；未接入后台 URLSession、BGTaskScheduler，不承诺后台持续上传。退到后台会停止实时取景。
- 触摸对焦只在取景帧头中找到与 JPEG 尺寸一致的字段、并跟随合理的整幅尺寸时开放；Z7 II 帧头布局未经真机确认。主体追踪、自动 Bulb、格式化存储卡、批量删除、Picture Control 写入、BLE 位置写入相机、Nikon ID/云创登录仍未实现。录像/调焦等已接通功能继续受机身能力和当前模式限制。
- 间隔拍摄、自动导入需要 App 保持前台；没有后台计时或后台下载。
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
