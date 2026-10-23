# Mac / iPhone / 相机 / NAS 验收清单

除已注明通过的云端编译外，其余条目仍需逐项执行，不能因为核心测试通过而勾选硬件验收。

## Xcode 与界面

- [x] 用云端 Xcode 27 / iOS 27 SDK 完成 Debug 模拟器编译与 Release ARM64 真机归档；解决本次 SwiftUI/CoreImage 编译诊断。
- [x] 核心测试与基础 UI Tests（39 核心项：38 通过/1 跳过；2 UI 项通过）。执行编号与日志见 TEST_SUMMARY.md。
- [ ] Instruments 性能分析；真机 Xcode build、iOS build、机型和性能报告。
- [ ] iPhone/iPad 竖横屏、最大动态字体、VoiceOver、Reduce Motion/Transparency、深浅环境对比、键盘避让。
- [ ] 真机签名与 Hotspot Configuration entitlement；本地网络/蓝牙权限允许、拒绝、撤回路径。
- [ ] 对有效 JPEG/HEIC/不同 NEF 压缩格式实测预览、方向、sRGB 导出。比较 identity LUT 前后颜色、黑白/曝光调整；原片 SHA256 保持不变。
- [ ] RAW/大量照片的缩略图内存、JPEG 导出内存、高温/低电量与低磁盘空间。

## Z7 II

- [ ] 执行 BLUETOOTH_AND_WAKE.md 的首配、系统绑定、重连、Wi-Fi 唤醒闭环；20 次成功率/延迟记录后才比较 SnapBridge。
- [ ] 校时/电量、手动断开与遗忘、拒绝网络许可、后台恢复及“关机时发送”各状态；不能由跨机型向量测试外推真机通过。

- [ ] 按 CAMERA_FEASIBILITY 顺序验证；记录固件与网络模式，先只读，再属性，再快门，再 Live View。
- [ ] 协议失败明确报错；禁止假图、禁止乐观“拍摄成功”。确认照片确实落盘后才统计拍摄成功。
- [ ] 10 分钟图传、热点切换、断网、相机休眠/断电、再连接、退后台与回前台、SnapBridge 争用。
- [ ] 多卡/200项截断提示/64MiB边界/下载字节比对、Unicode 文件名。
- [ ] 对未支持操作展示实际 unavailable，不将私有配对、视频和机内写入标成完成。

## NAS

- [ ] WebDAV 使用实际 NAS 有效证书和预先创建目录；PUT 后比较原片与远端大小/SHA256。
- [ ] S3 兼容服务验证 path-style、region、bucket、中文/空格对象 key、临时凭据 token；拒绝不正确签名。
- [ ] 401/403/404 进入受阻；408/429/503 进入退避；修正配置/凭据后的重试行为。
- [ ] 断网 → 入队 → 强退 → 重启 → 恢复网络 → 同一 key 成功，不产生第二个远端副本。
- [ ] App 暂停/锁屏的执行限制；明确向用户说明没有后台持续上传保证。
- [ ] 修改 NAS 配置时旧任务仍发往原目的地；无凭据泄漏、无自动跨域重定向。

## 发布前

- [ ] App icon/启动资源、本地化、支持与隐私政策、截图、签名分发、App Store Connect 与审核。
- [ ] 按实际 API 使用重新核对 PrivacyInfo.xcprivacy；文件大小等 required reason API 的声明不能仅靠当前静态模板判断。
- [ ] 凭据删除/目的地管理、任务取消/清理、资料库导出/备份/恢复、文件保护策略。
- [ ] 真实协议权限与 Nikon 商标/SDK/LUT 分发授权审查；没有官方授权时不宣称 Nikon 官方客户端。
