# ZORA 0.3 USB 与公开协议功能适配

日期：2026-10-23。代码实现、夹具测试、iOS 编译与相机互操作分别验收。

## USB 路线

使用 Apple 公开 ImageCaptureCore：ICDeviceBrowser 浏览 USB 相机；媒体与控制分别请求系统授权；仅接受 USB transport / Nikon VID 0x04B0 的设备；requestOpenSession 真正完成后，再读取 GetDeviceInfo 并校验 Nikon 厂商，才显示连接完成。

USB 和 Wi-Fi 共用 CameraSession、能力门禁、曝光、取景、文件、影像及 NAS 流程。USB 不套用 PTP/IP 的双 TCP 初始化，也不生成假的 OpenSession/CloseSession 响应。USB 生命周期属于系统，由真实 requestOpenSession/requestCloseSession 管理。

PTP USB 命令容器是小端 12 字节头加最多五个参数。ImageCaptureCore 的单次回调由请求 token 关联；系统可能重新分配 transaction ID，因此检查其真实响应容器/错误码，不篡改成应用期待的响应号。裸 USB 严格匹配 transaction 的解析路径仍保留并测试。

USB 请求有超时与取消处理；拔线使在途请求失败、事件流结束并清除连接。旧请求回调不能完成新的请求。关闭中的 USB 会话不允许同时重新打开。

## 已接通的功能矩阵

| 功能 | 公共 API / 可审查协议事实 | 适配方式 |
|---|---|---|
| USB 发现、授权、开关会话 | Apple ImageCaptureCore | 原生 iOS 接入，独立 USB 连接页 |
| PTP 设备信息/能力 | 1001 | USB 与 Wi-Fi 共享，只开放声明的操作 |
| 标准/落卡拍照 | 100E / Nikon 9207 | 声明 9207 时采用落卡参数 FFFFFFFF,0，否则用标准拍照；不会重放快门 |
| 实时取景 | Nikon 9201/9202/9203 | 共用真实 JPEG 路径；暂停轮询时保留相机取景状态，不重复 StartLiveView |
| 远程控制接管/释放 | Nikon 90C2，参数 1/0 | 用户主动接管；正常断开前释放本 App 持有的控制 |
| 录像启停 | Nikon 920A/920B | 两个操作都声明后显示；需相机视频模式，响应只表示指令被接受 |
| 手动调焦 | Nikon 9204，方向1近/2远、1–32767步 | 先保证 Live View，串行暂停图传轮询；有 DeviceReady 时有界查询完成；行程边界单独报告 |
| 终止连拍/长曝光 | Nikon 920C，0,0 | 显式按钮；不自动修改机身为 Bulb 模式 |
| 曝光/模式属性 | 1014/1016，5007/500D/500F/5010/5005/500E/500A/500B/5004/5013/5001 | 按设备属性集读描述，标量/枚举/范围约束后写；只读属性不能写 |
| 多卡标识/容量 | 1004/1005；声明时优先 Nikon 9209 | 卡选择、容量与剩余空间；读不到某张卡信息不伪造容量 |
| 文件分页 | 1007/1008 | 每页100，可继续读取第200项后内容；目录变化时要求刷新 |
| 缩略图 | 100A | 请求单个真实缩略图并验证完整 JPEG |
| 大 RAW 分块下载 | 101B | 4 MiB 上限分块、逐块响应字节数校验、临时文件、完整后提交；取消/错误不发布残片 |
| 相机事件 | PTP/IP Event 或 USB type4 | ObjectAdded/Removed、CaptureComplete 等解析与目录变更提示；拔线清理 |

“Nikon 扩展”表示公开参考实现中的命令事实，不表示 Nikon 官方 SDK 已授权、也不表示所有固件兼容。每项仍受 GetDeviceInfo 能力门禁和相机实际响应控制。

## 本次保留的边界

- iPhone/iPad USB-C 需支持数据的线；Lightning 需要相机连接转接器，可能还需外部供电。模拟器明确提示不能连接真实 USB 相机，不制造演示设备。
- 真实 Z7 II 的 USB 身份、固件、线材、权限、录像/调焦行为尚待验收。编译或夹具不证明互操作。
- 分块下载支持标准 32 位大小/偏移：拒绝 FFFFFFFF 未知大小和需要64位扩展的对象。超过原64 MiB的普通 NEF 已有独立测试；大于等于4 GiB视频、跨重启断点续传未实现。
- 未支持 101B 的相机保留单次64 MiB内存上限。没有通过提高内存上限假装解决大文件。
- 触摸对焦与主体追踪需要正确的 Nikon 取景 whole-size 坐标系，不能把 JPEG 屏幕坐标直接发送；未核验模型帧头前不开放。没有猜测 Power Zoom、云创机内写入、设置备份等新机扩展。
- 本次未添加格式化卡、批量删除、复位、固件更新等破坏性操作；不是以“所有公开协议”名义自动执行这些命令。
- 录像指令接受不等于落盘完成；断开连接不保证停止相机上已经开始的录像，需看机身录制指示。

## 来源

- [Apple ImageCaptureCore](https://developer.apple.com/documentation/imagecapturecore/)：iOS 外接相机用途说明、浏览/控制公共 API。
- [Apple requestSendPTPCommand](https://developer.apple.com/documentation/imagecapturecore/iccameradevice/requestsendptpcommand(_:outdata:completion:))：真实命令与完成回调。
- [Cascable 有线连接说明](https://www.cascable.app/help/wired-cameras/)：USB-C/Lightning 连接、模式与权限；[Z7 II 兼容信息](https://compatibility.cascable.se/nikon/z7-ii/)。
- [libgphoto2 ptp.h](https://github.com/gphoto/libgphoto2/blob/master/camlibs/ptp2/ptp.h)：交叉核对标准容器、事件和命令事实；未复制或链接该库代码。
- [ZPill MIT 参考实现](https://github.com/jaminxx-aha/ZPill/tree/76d4c8ed6bce0da1a962ffc7fc9e7ccc8e1f3afd)：交叉核对 USB 系统事务号/会话所有权、Nikon 扩展参数。平台层重写为原生异步 Swift，无 Flutter、信号量或合成 ACK；原 MIT 声明继续随 App 打包。

## 验收

核心新增测试覆盖 USB 容器和错误响应、事件一致性、系统会话不伪造开关命令、断线、能力门禁、视频/调焦参数、控制释放、250项分页、65 MiB以上 RAW、错误分块不留残片及重复取景启动。最终计数与云端结果见 TEST_SUMMARY.md。

真机执行：先只读枚举/授权/设备信息/卡信息，再逐个验证取景/接管/拍照/录像/近远调焦；测试中途拔线、权限拒绝、相机断电、切换无线、错误模式和写卡忙。大 RAW 下载后比较相机原件与入库文件大小/SHA256；不得以 PTP OK 响应代替照片/视频落盘验证。
