# ZORA Camera 软件交接说明 · 0.5

交接版本：**0.5.0（build 5）**　交接日期：2026-11-03　上一版：0.4.0（build 4）

## 1. 本轮做了什么

在 0.4 源码基础上补齐了一批 Nikon/PTP 协议功能和摄影 App 常用功能，并完善了 0.4 中不完整的部分。逐项说明见 `Docs/RELEASE_0.5.md`，摘要如下：

- **协议功能**：Nikon CheckEvent（90C7）事件轮询、拍摄后自动导入（4002）、设置变化同步（4006）、触摸对焦（9205，帧头自校验后才开放）、DeviceReady 等待、单文件删除（100B）、分块下载断点续传、设备能力清单。
- **拍摄工具**：延时快门、间隔拍摄、包围曝光（曝光补偿/快门/ISO）、焦点包围。
- **完善项**：曝光参数可读显示（f/5.6、1/250、+0.3 EV…）、取景信息条与放大检焦、相机文件筛选/批量导入/进度、相机文件名保留、照片收藏/评分/删除/筛选、手机定位地理标签与 GPS EXIF、导出保留 EXIF 并修正方向、LUT 库持久化、Recipe 新调色项与自定义保存、WebDAV 自动建目录、上传后大小核对、上传任务清理。

## 2. 重要：验证状态

本轮开发环境为 Windows，**没有 Swift 编译器、没有 Xcode、没有 git**。代码经过人工与静态复核，但：

- 未编译，未运行任何测试；
- 没有生成新的 IPA（交接包中的 IPA 仍是 0.4）；
- 未推送到 GitHub。

接手第一步：把源码放到仓库新分支 → 推送 → 跑 `Swift core and iOS` 工作流（或在 Mac 上 `swift test` + 模拟器构建）→ 修编译诊断 → 再跑 `Build ZORA IPA`。

## 3. 建议的验证顺序

1. CI 全绿（核心测试含新增 `FeatureTests` 16 项；UI 冒烟 3 项）。
2. 不连相机：照片导入、收藏/评分/删除、新 Recipe 滑杆、保存风格、LUT 重启保留、开启定位后导出 JPEG 查看 GPS。
3. 连 Z7 II（先按 0.4 的 `PAIRING_FLOW_REPAIR.md` 完成配对）：设置 → 分享能力清单，确认声明了哪些操作码。
4. 按 `HARDWARE_ACCEPTANCE.md` 中“0.5 新功能”逐项验收；触摸对焦若显示“对焦坐标未校验”，说明帧头布局与假设不同，需要采集一帧原始数据分析。
5. 通过后更新 `CAMERA_FEASIBILITY.md` 的真机状态列。

## 4. 新文件与结构变化

```text
Sources/ZoraCore/CaptureSequences.swift   间隔/包围/焦点包围计划（纯逻辑，可测试）
iOS/Services/Location.swift               前台定位（CLLocationUpdate + CLServiceSession）
iOS/Views/ShootingToolsView.swift         拍摄工具页
iOS/Views/CameraFilesView.swift           从 CameraView 拆出并扩展
iOS/Views/ConnectionView.swift            从 CameraView 拆出（内容未改，事件显示名称）
Tests/ZoraCoreTests/FeatureTests.swift    0.5 功能测试
Docs/RELEASE_0.5.md                       本轮更新说明
```

`Info.plist` 新增 `NSLocationWhenInUseUsageDescription`；版本 0.5.0 / 5；Xcode 工程已由 `Tools/generate_project.py` 重新生成。

## 5. 数据兼容

- 0.4 的 `library.json`、`recipes.json`、`uploads.json` 可直接读取；新字段均为可选或带默认值。
- LUT 改为保存在 `Application Support/ZORA/LUTs/`；0.4 未持久化 LUT，升级后需重新导入一次。
- 相机蓝牙身份、Wi-Fi 资料和 NAS 凭据的存储方式未变。

## 6. 已知风险

- 触摸对焦的帧头坐标假设（大端 16 位“JPEG 宽高 + 整幅宽高”）来自对 Nikon 取景数据结构的一般认识，未在 Z7 II 上验证；校验不通过时功能保持关闭，不会发送错误坐标。
- 曝光值名称表（白平衡、模式等 0x80xx 厂商值）未逐一在 Z7 II 核对；未知值以十六进制显示。
- 自动导入在相机写卡完成前收到事件时会重试，最多 6 次；极慢写卡（长曝光降噪）可能需要手动再导入。
- 取景过程中下载：若相机拒绝，会等取景停止后再导入。
