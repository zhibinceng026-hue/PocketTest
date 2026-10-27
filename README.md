# 口袋测试 / PocketTest

一个用于验证 iPhone 原生 App 链路的最小 SwiftUI 工程，支持 iOS 16 及以上。

功能：点击加一、自动保存到本机、确认后清零。无需登录、联网或隐私权限。

## 当前状态

已准备源码、Xcode 工程、GitHub Actions 编译配置和未签名 IPA 打包脚本。
本机为 Windows，尚未使用 Xcode 编译；尚未生成 IPA，也尚未在 iPhone 上运行。
只有实际编译、签名安装、打开并验证后，才能确认完整链路已打通。

## Windows + GitHub + SideStore / AltStore

1. 在 GitHub 准备测试仓库，把本目录的内容放到仓库根目录（包含隐藏的 `.github` 目录）。
2. 公开仓库使用标准 GitHub 托管 macOS runner 的编译时间免费。私人仓库会消耗账户额度；本测试没有苹果账号或私密数据。
3. 推送到 `main` 会启动编译，也可以在 Actions → Build iPhone test app → Run workflow 手动启动。
4. 成功后从本次运行的 Artifacts 下载 `PocketTest-unsigned`，解压得到 `PocketTest-unsigned.ipa`。
5. 将 IPA 保存到 iPhone 的“文件”，用现有的 SideStore / AltStore 导入并签名安装。
6. Apple 账号密码和验证码由你在签名工具内自行输入；无需上传给 GitHub 或发给他人。
7. App 应加入签名工具的应用列表，再检查它是否能成功刷新续签。

源码没有第三方库；云端只做未签名构建，不需要 Apple 证书、配对文件或账号。

## 真机验收

- 主屏幕出现“口袋测试”，能打开原生界面。
- 点击按钮三次，显示 3。
- 从多任务界面彻底退出 App，再打开，仍显示 3。
- 点“清零”并确认，数字回到 0。
- 在 SideStore / AltStore 执行一次刷新，确认这款 App 也刷新成功；之后再验证自动续签。

免费开发签名仍有 7 天有效期；自动续签是在过期前刷新，并非永久证书。
SideStore 和 AltStore Classic 的后台刷新条件不同，以已安装版本的官方文档为准。
免费账号的应用数量限制仍然适用，不要为了测试删除现有 App 或数据。

## 如果以后有 Mac

双击 `PocketTest.xcodeproj`，在 Signing & Capabilities 选择自己的 Team，连接 iPhone 后点击运行。
只生成未签名 IPA 则在项目目录执行 `bash scripts/build-unsigned.sh`。

## 官方资料

- [SideStore FAQ：后台刷新续签](https://docs.sidestore.io/docs/faq)
- [AltStore Classic：刷新与后台刷新](https://faq.altstore.io/altstore-classic/your-altstore)
- [Apple：免费开发账户限制](https://developer.apple.com/help/account/basics/about-your-developer-account/)
- [GitHub Actions：计费与免费范围](https://docs.github.com/en/actions/concepts/billing-and-usage)
