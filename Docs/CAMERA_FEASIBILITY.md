# Z7 II 相机通信可行性矩阵

核对日期：2026-10-23，0.3.0。验证分为“官方产品功能证据”“代码已实现”“本环境自动测试”“Z7 II 真机验证”；它们不能互相替代。USB/扩展协议详表见 USB_AND_PUBLIC_PROTOCOLS.md。

| 能力 | 公开证据与路线 | 工程实现 | 真机状态 / 边界 |
|---|---|---|---|
| Wi-Fi 遥控、实时取景 | Nikon Z7 II 手册及 SnapBridge 文档确认产品能力 | NWConnection TCP，PTP/IP 双通道，Nikon 0x9201/02/03 实验调用 | 未验证第三方协议兼容；产品功能存在不等于通用协议可访问 |
| 蓝牙认证/唤醒 | CoreBluetooth + DE00/2000/2002/2005 | 真实四阶段认证、保存身份、Wi-Fi 唤醒、自动重连 | 字节级向量已通过；Z7 II 系统绑定和固件方言仍需真机验证，见 BLUETOOTH_AND_WAKE.md |
| 加入相机热点 | NEHotspotConfiguration 公共 API | 输入 SSID/密码，系统批准，joinOnce | 需 Apple 签名 entitlement 与真机；不推断热点参数 |
| PTP/IP 初始化 | 独立编码；参考 libgphoto2 公共实现的协议字段 | GUID、UTF16 名称、15740 可见默认端口、命令/事件 ACK、Ping/Pong | Z7 II 模式、配对、握手差异待查；拒绝立即失败 |
| 能力读取 | GetDeviceInfo 0x1001 | 读取厂商、固件、操作集与属性集后开放控件 | 声明支持仍不等于当前拍摄模式允许执行 |
| 快门 | 标准 100E / Nikon 9207 | 优先设备声明的落卡指令；检查响应，不自动重放快门 | 实际模式、落盘与响应语义待真机验证 |
| 光圈/快门/ISO/白平衡/EV | GetDevicePropDesc / SetDevicePropValue | 仅标量、枚举/范围检查，按描述符宽度编码，写后重新读 | 特定模式下可能只读，vendor 专属属性未接入 |
| 自动对焦 | Nikon 0x90C1 公共社区实现常量 | 设备声明该操作才启用 | 相机工作模式及镜头需验证 |
| Live View | Nikon 社区实现常量 0x9201/02/03 | 周期拉帧；受限范围内提取完整 JPEG；失败停止 | 头部变体、DeviceReady/ChangeCameraMode 前序与速率需验证 |
| 相机文件列表/原片 | PTP 1004/1005/1007/1008/100A/101B，Nikon 9209 | 多卡、容量、100项分页、真实缩略图、4MiB分块、完整提交 | 普通NEF可超过64MiB；64位大小/偏移、跨重启断点续传未实现 |
| 事件通道 | PTP/IP Event / USB type4 | 解析事件、记录目录变化、拔线清理；错误关闭会话 | 事件用于刷新提示，不伪造本地照片或自动统计落盘成功 |
| Nikon SDK | 官方 Remote Module SDK 提供 Z7 II 支持，面向计算机 | 未捆绑二进制 SDK；不假定可链接 iOS | 获取并审查授权/平台后才能决定桌面桥接扩展 |
| Nikon Imaging Cloud | 官方兼容列表未列 Z7 II | 独立手机端 Recipes / LUT / JPEG 导出 | 不模拟 Nikon ID，不突破机身兼容性，不声称官方滤镜完全复现 |
| USB 原生连接 | Apple ImageCaptureCore | 媒体/控制授权、系统会话、真实 PTP 命令与响应；与 Wi-Fi 共用核心 | 已实现平台接入，Z7 II 与线材/权限待真机验证 |
| 录像/手动焦点/控制接管 | 公开参考实现 Nikon 920A/B、9204、90C8、90C2 | 能力门禁、就绪查询、近远调焦、接管释放、920C终止捕获 | 参数/模式/镜头与实际完成状态须真机核验 |

## 协议实现策略

生产路径没有 MockCamera。所有网络字节来自真实 TCP；PTP/IP 是实验性通用实现，不能承诺满足 Z7 II 的 SnapBridge 私有协议。UI 的“连接”必须依次完成初始化、事件通道、GetDeviceInfo、OpenSession 后才成功。读取操作码集限制功能入口；相机拒绝操作会报告错误。握手超时不自动替换为演示图像。

核心协议测试使用明确命名的 `ScriptedTransport`，仅存在于 Tests。未复制或链接 libgphoto2 源码；参考其公开常量与线格式后独立实现，不随工程分发 GPL/LGPL 库。

## 真机验证顺序

1. 记录 Z7 II C 固件、相机网络模式、iPhone/iOS/Xcode 版本；不记录/上传密码。
2. 在相机授权的 Wi-Fi 中确认地址、端口、是否必须先建立 Nikon 私有蓝牙绑定。取得用户控制设备的合法协议样本后补充认证，禁止凭空编造。
3. 先只读 GetDeviceInfo；保存去除序列号的能力清单。确认 OpenSession/CloseSession、重连、权限拒绝、后台回前台。
4. 验证各属性描述、允许值、P/S/A/M 只读差异、写后回读。
5. 单次快门 → 手动刷新对象列表 → 下载 JPEG → 比较相机原文件字节/哈希。网络中断时不自动重发快门。
6. 开/关取景，确认 0x9203 图像布局、JPEG 可解码、色彩/方向、断网停止与重连；测 10 分钟耗电/温度/帧率/延迟。
7. 再验证 AF、RAW 下载大小上限、多卡、超时、相机忙、断电、SnapBridge 争用。

## 来源

- [Nikon Z7 II / Z6 II：连接智能设备](https://onlinemanual.nikonimglib.com/z7II_z6II/en/10_establishing_wireless_connections_03.html)
- [SnapBridge：Remote Photography with Live View](https://nikonimglib.com/snbr/onlinehelp/en/remote_photography_with_live_view_17.html)
- [Nikon SDK 下载说明](https://sdk.nikonimaging.com/apply/)
- [Nikon SDK 更新与 FAQ](https://sdk.nikonimaging.com/information/en/)
- [Nikon Imaging Cloud 官方兼容说明](https://www.nikon-asia.com/nikon-imaging-cloud)
- [libgphoto2 PTP/IP 公共实现](https://github.com/gphoto/libgphoto2/blob/master/camlibs/ptp2/ptpip.c)
- [libgphoto2 Nikon 操作码定义](https://github.com/gphoto/libgphoto2/blob/master/camlibs/ptp2/ptp.h)
- [Apple：Liquid Glass 自定义视图](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [Apple：iOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)
