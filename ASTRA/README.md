# ASTRA · 星空堆栈与调色

iOS 原生工程，最低 iOS 26。GitHub Actions 构建未签名 IPA；签名需要用户自己的有效证书和描述文件。Android 工程共享 C++ 堆栈内核，界面功能更新以各平台实际版本为准。

## iOS 功能

- 相册 RAW+JPEG 资产：通过 Photos 资产资源找到原始 NEF/RAW 和 JPEG，选择一种格式导入；系统会要求读取相册原件的权限。若相册不给出原件或拒绝授权，可使用「从文件导入」选择 NEF。导入后以文件扩展名保存，并由系统 CIRAWFilter 解码，不以内嵌 JPEG 冒充 RAW。
- 星点对齐：三角星型匹配、全尺寸星点精修、曝光与背景归一化、饱和星点识别；可选主图与主体框。匹配失败的帧在照片列表显示原因。
- 分块堆栈：Float16 临时帧缓存、Float32 线性主文件；稳健剔除、星轨、水平天空与地景分离。
- HDR 多曝光融合：开启后对齐长短曝光，用未饱和短曝光像素恢复高光核心；微弱信号侧提高长曝光权重。应使用同一目标、相同焦距和构图的多档曝光。
- 自动 STF：合成结果默认仅在屏幕拉伸预览；线性主文件和导出不受 STF 影响。
- 星云工具：Arcsinh 色彩保留拉伸、亮核保护、低频网格背景梯度消除、星云对比与高频星点保护。除了 STF，这些调整会应用于全尺寸导出；工具强度可手动调节。亮核保护是连续亮度掩膜，不是 PixInsight 的完整迭代 Masked Stretch。
- 曲线、六色 HSL、色轮、降噪与全尺寸 TIFF/PNG/JPEG/HEIF 导出。

## 构建与验证

`bash Scripts/test_core.sh` 验证几何配准、不同曝光、饱和星点、HDR 高光恢复、真实像素合成与中途取消。`python3 Scripts/validate_package.py` 检查 Xcode 项目结构。GitHub macOS runner 进行 iOS 模拟器 UI 回归、主文件逐帧检查和 arm64 设备包归档。没有用户原始 M42 NEF 和 iPhone 真机测试，实际 RAW 支持取决于运行设备的系统解码器与照片资源权限。

使用自己的 Mac 可运行 `bash Scripts/build-unsigned.sh`。未签名 IPA 需重新签名才能安装，不能直接提交 TestFlight。工程数据位于 App 的 Documents/ASTRA，卸载 App 前请从文件 App 备份。
