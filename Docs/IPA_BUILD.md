# IPA 打包

目前本机为 Windows。源码压缩包不是 IPA，核心 Swift 测试通过也不代表已编译 iOS App。

## GitHub 云端构建

将此项目的内容放到仓库根目录（根目录应有 Package.swift、iOS/、.github/）。`Build ZORA IPA` 工作流使用 GitHub 官方提供的 `xcode-27` runner。向 main 或 codex/zora-ipa 推送相关源码后自动构建，也可以在 Actions 中手动运行。

成功后在该次运行的 Artifacts 下载 `ZORACamera-unsigned-IPA`，解压后取得 `ZORACamera-unsigned.ipa` 与 `IPA_BUILD_REPORT.json`。若构建失败，不会上传虚假 IPA；日志保存在 `ZORACamera-build-errors`。

**默认产物未签名，需要另外签名才能安装运行。** 本次没有 Apple 证书或描述文件，不能把未签名包称为直接安装版。Hotspot Configuration 能力还需要相应签名授权；如签名服务不支持该能力，可使用系统设置手动加入相机 Wi-Fi，但最终签名/运行仍须实测。

工作流不需要 Apple 密码、不读取签名证书、不上传 App Store。GitHub 构建器的可用性与用量由你的账户决定。

## 在 Mac 上生成未签名 IPA

```sh
python3 Tools/build_ipa.py --unsigned
```

脚本要求 macOS + Xcode + iOS 27 SDK，先构建 ARM64 真机 archive，再以 Payload/*.app 布局打包；核对可执行文件 Mach-O 架构、LC_BUILD_VERSION 的 iOS 设备标识，拒绝模拟器或源码改名。Builds/ 下保存日志与报告。

## 使用自己的签名导出

在自己的 Mac/Xcode 中配置 Team、证书与包含 Hotspot Configuration 的描述文件，并从 Xcode 导出一份采用本地 export 的 ExportOptions.plist，然后执行：

```sh
python3 Tools/build_ipa.py --signed --team-id YOUR_TEAM_ID \
  --bundle-id YOUR_REGISTERED_BUNDLE_ID --export-options /path/to/ExportOptions.plist
```

证书私钥保留在你的钥匙串。脚本不自动上传、不自动注册设备。正式导出后执行 codesign 验证，并检查 embedded.mobileprovision；是否能在某台手机安装仍受描述文件设备范围与有效期限制。

## 本地已验证的部分

Windows 上只运行打包工具的合成夹具验证和非 Mac 环境拒绝测试；没有产出 IPA。真正 Xcode 编译结果以 GitHub Actions 的运行记录与产物为准。

来源：[GitHub Xcode 27 runner](https://github.com/actions/runner-images/issues/14404)、[Apple archive 导出](https://help.apple.com/xcode/mac/current/en.lproj/deva1f2ab5a2.html)、[Apple 设备运行与签名要求](https://help.apple.com/xcode/mac/current/en.lproj/dev5a825a1ca.html)、[GitHub Apple 签名材料配置](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)。
