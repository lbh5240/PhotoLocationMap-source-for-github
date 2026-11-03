# ZORA 0.5.0（build 5）更新说明

日期：2026-11-03。基于 0.4.0 交接包继续开发。

**验证状态：** 本轮在没有 Swift 工具链的 Windows 环境完成，代码经过人工逐行与静态复核，但**尚未编译、尚未运行测试**。合并后第一件事是跑 `swift test` 和 iOS 模拟器构建（CI 工作流 `Swift core and iOS`），修完编译诊断后再打 IPA。所有相机功能仍需 Z7 II 真机验收。

## 新增的 Nikon / PTP 协议功能

| 功能 | 指令 / 数据 | 实现与门禁 | 真机待验 |
|---|---|---|---|
| 事件轮询 | Nikon CheckEvent 0x90C7：UInt16 数量 + n×(UInt16 事件码, UInt32 参数) | 相机声明 90C7 才发送；与 PTP/IP 事件通道、USB 中断事件合并到同一事件序列，序号单调递增 | Z7 II 是否声明 90C7、事件是否重复 |
| 拍摄后自动导入 | 事件 0x4002 ObjectAdded → 1008 → 101B/1009 | 设置开启后，新文件按 JPEG/HEIF（可选 RAW）下载入库；对象标识 = 存储卡+文件名+大小+拍摄时间，不重复导入；相机忙 0x2019 或取景中拒绝时最多重试 6 次 | 写卡完成前事件到达的时序；取景中下载是否被允许 |
| 设置变化同步 | 事件 0x4006 DevicePropChanged | 收到后重新读取属性描述，机身拨盘改动会反映到 App | — |
| 触摸对焦 | Nikon ChangeAfArea 0x9205（x, y 为整幅坐标） | 只在取景帧头中找到与 JPEG SOF 尺寸一致的 16 位字段对、紧随其后有比例一致（±4%）的整幅尺寸时开放；否则界面显示“对焦坐标未校验”。设置区域后若声明 90C1 则触发对焦 | **Z7 II 帧头布局未知**，可能始终不开放；坐标方向/旋转需实测 |
| 取消对焦 | Nikon AfDriveCancel 0x9206 | 核心 API 已提供，界面未接入 | — |
| 就绪等待 | Nikon DeviceReady 0x90C8 | 序列拍摄每张之间等待就绪（忙 0x2019 时 100 ms 轮询，10 秒上限）；未声明时直接继续 | 长曝光/写卡时长 |
| 删除单个文件 | DeleteObject 0x100B（handle, 0） | 声明才显示；左滑 + 二次确认；成功后目录修订号递增 | 受保护文件的拒绝码 |
| 下载续传 | GetPartialObject 0x101B | 临时文件名由对象标识哈希得出；断线/取消/超时保留已收部分，重连后从该偏移续传；数据长度错误时丢弃。单块遇 0x2019 重试 2 次 | 跨重启续传、相机重新编号后标识是否一致 |
| 曝光参数可读化 | 5007/500D/D100/500F/5010/5005/500E/500A/500B/5004/5013/500C/5001 | 光圈 f/5.6、快门 1/250 或 2.5″（500D 吸附到标准档位；Nikon D100 按分子/分母解析）、±EV、ISO、白平衡/模式/对焦/测光/画质/释放模式中文名；未知值显示十六进制，不猜 | Z7 II 实际枚举值是否与表一致 |
| 能力清单 | DeviceInfo 中的操作、事件、属性集合 | 设置页列出操作名称；可分享不含序列号的能力清单，便于下一轮适配 | — |

## 新增拍摄工具（只组合相机已声明的指令）

- **延时快门**：手机倒计时 1–60 秒后一次快门。
- **间隔拍摄**：2–9999 张、1–3600 秒间隔、可设开始前等待。按绝对时间槽调度，某张耗时超过间隔时跳过错过的时间点，不连续补拍；空档内顺带处理自动导入。
- **包围曝光**：曝光补偿 / 快门 / ISO 三选一，3/5/7/9 张，间隔 1–12 档（“档”= 相机列出的相邻可选值）。只用相机声明的值，顺序 0、−、+…，拍完（包括出错或取消）恢复原值。快门进入 B/T 门时拒绝。
- **焦点包围**：2–300 张，每张驱动 9204 固定步长，到镜头行程边界自动结束。

全部在 `perform` 中运行，界面显示进度和“停止”，取消在指令之间生效。

## 完善的现有功能

- 相机下载入库时保留相机文件名（0.4 会以临时 UUID 作为照片名）。
- 照片库：收藏、0–5 星评分、筛选（收藏/RAW/JPEG/有位置）、删除（先删索引再删文件）。0.4 的 `library.json` 可直接读取。
- 地理标签：设置中开启后，自动/手动从相机导入的照片记录 10 分钟内的 iPhone 定位；导出 JPEG 写入 GPS EXIF。相机原片不改写，也不经 BLE 写入相机。
- 导出：保留源 EXIF，方向标签重置为 1（像素已旋正，避免二次旋转），JPEG 质量 0.92，文件名改为“原名-ZORA-xxxxxx.jpg”。
- Recipe：新增色调、高光恢复、阴影、自然饱和、暗角、颗粒；旧 Recipe JSON 缺字段时取中性值。新增 4 个原创预设。编辑器可“保存为新风格”，风格页长按可导出 JSON 或删除自定义风格。
- LUT：导入后复制到 App 资料目录，重启后仍在；可在多个 LUT 间切换或删除。
- 相机文件页：类型筛选、拍摄时间、存储卡用量条与可拍张数、已导入标记、批量导入、下载进度、视频不再进入照片库（给出提示）。
- 拍摄页：取景信息条、放大检焦 1×/2×/4×（以对焦点为中心）、对焦框、属性刷新按钮、只读属性显示锁标识、连接图标区分 USB/Wi-Fi。
- NAS：WebDAV 返回 404/409 时逐级 MKCOL 建目录后重试一次；上传后 HEAD 核对 Content-Length（不一致则重传，服务器不回报则标记未核对）；清除已完成、左滑移除任务；上传过程中移除/清理不会写错任务（按 ID 重新定位）。
- 设置页“驱动状态”按实际连接方式显示（0.4 一律写 PTP/IP）。

## 新增 / 修改的文件

- 核心：`CaptureSequences.swift`（新）；`PTP.swift`、`PTPUSB.swift`、`CameraProperty.swift`、`CameraSession.swift`、`Library.swift`、`Imaging.swift`、`Upload.swift`。
- iOS：`Services/Location.swift`（新）、`Views/ShootingToolsView.swift`（新）、`Views/CameraFilesView.swift` 与 `Views/ConnectionView.swift`（从 CameraView 拆出）；其余页面与 `AppModel.swift` 更新。`Info.plist` 增加定位用途说明，版本 0.5.0 / 5。
- 测试：`Tests/ZoraCoreTests/FeatureTests.swift`（新，16 项）。
- 工程：已用 `Tools/generate_project.py` 重新生成。

## 仍未实现（有意保留）

- 格式化存储卡、批量删除、固件更新、设置复位：破坏性，不做。
- Picture Control 读写（90CC/90CD）、Nikon 主体追踪、Power Zoom、BLE 位置写入相机：数据格式未经可审查来源核对，不凭猜测实现。
- 64 位对象（≥4 GiB 视频）、S3 multipart、后台上传/后台间隔拍摄。
- Nikon ID / Imaging Cloud 登录与云创配方下发。

## 参考

- [libgphoto2 ptp.h](https://github.com/gphoto/libgphoto2/blob/master/camlibs/ptp2/ptp.h)：90C7、9205、9206、100B 等操作码和事件码交叉核对；未复制或链接其代码。
- [Apple CLLocationUpdate](https://developer.apple.com/documentation/corelocation/cllocationupdate) / [CLServiceSession](https://developer.apple.com/documentation/corelocation/clservicesession)。
- [RFC 4918 WebDAV MKCOL](https://www.rfc-editor.org/rfc/rfc4918#section-9.3)。
