# ZORA 0.2 蓝牙与自动唤醒开发报告

> 历史记录：以下描述 0.2 实现。本次 0.4 审核发现其名称写入后的注册不完整，已重写原生流程；现行行为、恢复步骤与验证边界以 [PAIRING_FLOW_REPAIR.md](PAIRING_FLOW_REPAIR.md) 为准。四阶段挑战测试不能证明系统配对或相机注册完成。

日期：2026-10-23。状态：实现真实协议和原生平台接入；Z7 II 真机验收待执行。

## 本次交付

- CoreBluetooth 连接、Nikon DE00 服务发现、2000 indication 订阅、17 字节四阶段认证、2002 控制器名称确认写入。
- 纯 Swift Blowfish / CBC-MAC 挑战核验。无匹配盐、错误顺序、截断帧、非法序列号均拒绝，认证前不发送 Wi-Fi 唤醒。
- 已认证身份保存在 ThisDeviceOnly 钥匙串；重连复用 device/nonce，并生成新的随机挑战。相同外设 UUID 返回不同序列号时要求人工确认。
- 2005 写入 `01` 请求启用相机 Wi-Fi，等待热点、用 NetworkExtension 加入、再执行 GetDeviceInfo / OpenSession，最后才显示 PTP 连接成功。
- SSID、密码、相机地址首次由用户输入并存入钥匙串，与相机 UUID 绑定。不采用未经证实的 2004 凭据解密猜测。
- 自动重连 2/4/8/16/30 秒，最多五次；手动断开立即停止自动重试；遗忘删除本机身份及相机 Wi-Fi 凭据。
- CoreBluetooth 状态恢复、bluetooth-central 后台声明。前台可定期校时/读取相机声明的电量特征；不承诺 iOS 后台定时运行。
- 前台恢复可自动走“认证 → 唤醒 → 加入网络 → PTP 验证”，不会在后台弹网络加入请求。
- 分阶段状态、按信号强度排序的 Nikon 扫描结果、不含密钥/密码/原始认证帧的环形诊断及分享。
- 系统蓝牙配件选择器作为手动绑定辅助入口；选择器结束不作为认证或系统绑定成功证明。SwiftUI Scene 生命周期下其显示行为需真机核验，失败时提供 iPhone 蓝牙设置路径。

## 可行性矩阵

| 功能 | 代码/协议证据 | 验证结论 |
|---|---|---|
| Nikon BLE 发现 | Company ID 0x0399、DE00 service、已保存 UUID | 原生接入已编写，需实际广播核验 |
| BLE 链路与四阶段认证 | 2000 + 2002；MIT 参考实现、公开 Z50 II 样本 | 字节级测试通过；Z7 II 固件方言待测 |
| iOS 系统绑定 | CoreBluetooth 系统安全提示；公开 EA accessory picker 辅助 | 系统绑定不由应用伪造；首配/重连各需真机测试 |
| Wi-Fi 唤醒 | 2005 `01` 写入，必须等待 GATT write response | 已实现；写入被接受不等于相机已唤醒 |
| 自动进入拍摄 | Keychain Wi-Fi profile → NEHotspotConfiguration → PTP | 已连接完整代码路径；需相机与签名 entitlement |
| 电量 / 校时 | Nikon 自定义 2A19、2006 10-byte UTC + signed timezone | 布局测试通过，实际支持情况待测 |
| 后台恢复 | CBCentral restore identifier、已知相机白名单 | 已实现恢复回调；系统调度、休眠/关机模式待测 |
| 断电/飞行模式唤醒 | 无可达无线链路 | 无法保证，界面明确说明 |

## 研究与取舍

1. [Nikon Z7 II 官方连接说明](https://onlinemanual.nikonimglib.com/z7II_z6II/en/10_establishing_wireless_connections_03.html) 与 [SnapBridge 连接故障说明](https://nikonimglib.com/snbr/onlinehelp/en/connection_issues_48.html)：蓝牙必须在相机与手机开启；关机连接取决于 send while off 等条件。首次配对仍需用户确认配对码。
2. [Cascable 的 Z7 II 兼容表](https://compatibility.cascable.se/nikon/z7-ii/)：Wi-Fi/USB、取景、自动拍摄、RAW、存储卡访问是可参考方向。其说明建议关闭蓝牙获得稳定连接，因此不能把该表当成“Z7 II 蓝牙唤醒已验证”的证据。
3. [ZPill](https://github.com/jaminxx-aha/ZPill/tree/76d4c8ed6bce0da1a962ffc7fc9e7ccc8e1f3afd)，MIT，主要硬件开发机型 Zf。借鉴其公开配对帧、挑战算法和命令事实，重新编写原生 Swift 平台层；MIT 完整声明已随 App 打包。Z50 II 样本只能证明移植的字节算法一致，不证明 Z7 II 互操作。
4. [Apple 系统配件选择器](https://developer.apple.com/documentation/externalaccessory/eaaccessorymanager/showbluetoothaccessorypicker%28withnamefilter%3Acompletion%3A%29)：仅使用公开 API；系统绑定结果和应用层 Nikon 认证分别处理。

没有复制闭源第三方应用代码，没有读取 Nikon 账号或搬运官方云端滤镜。本版保留已有独立 Recipes/LUT、RAW 管理与 WebDAV/S3 队列。

## 测试

- Windows Swift 6.2 核心共 39 项，38 通过、0 失败、1 项 HTTPS 夹具未配置跳过。新增 BLE 9 项全部通过。
- 已覆盖标准 Blowfish 零密钥向量、公开 Z50 II challenge/stage3 逐字节向量、篡改挑战、乱序/重放/非法长度、序列号验证、认证前唤醒拒绝、身份复用与新挑战、负半小时时区、名称长度与有限重试。
- iOS Swift 源码语法检查、云端 Xcode 27.1 平台类型检查、模拟器编译与 ARM64 真机归档均通过。交付包与源码提交、SHA256 见 IPA_DELIVERY.md。
- 本版基础 UI 两项已在云端执行通过，最终交付提交的执行证据另见 TEST_SUMMARY.md 与 UI_TEST_RESULTS.txt；UI 不替代真机蓝牙/相机联调。

## 真机验收步骤

1. 记录 iPhone/iOS、相机型号 Z7 II/固件、原 SnapBridge 绑定状态。首次在相机配对菜单选择 ZORA，确认配对码；观察四阶段认证与系统绑定分别完成。
2. 保存相机热点资料；点击唤醒连接，检查蓝牙写响应、真实热点出现、iOS 加网许可、PTP 设备型号及会话全部成立。故意输错密码不显示已连接。
3. 正常待机、关机时发送开/关、断电、飞行模式逐一测试；重复 20 次，记录成功率和 P50/P95 延迟，之后才可比较 SnapBridge。
4. 断线后最多五次退避；关闭开关、手动断开、遗忘相机后不得继续唤醒。不同相机资料不得混用。
5. 退后台、锁屏、系统回收、强制退出、回前台、蓝牙权限拒绝/撤回、iOS 蓝牙关闭逐项记录。后台不能保证持续运行，前台恢复应可重试。
6. 检查相机时间（含 DST/负时区）与电量；SnapBridge 抢占、双卡忙、录像中被拒绝时如实提示。

性能、可靠性超过原厂软件是验收目标，当前没有硬件基准测试，不能声称已经达到。
