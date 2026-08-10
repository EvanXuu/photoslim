# PhotoSlim

原生 macOS 照片与视频压缩工具。在修改 Apple 照片图库前，PhotoSlim 会先把压缩结果保存在本机，完成格式与元数据验证，并让你逐项对比原件。

> **0.1 Alpha**：这是面向小规模真实图库测试的早期版本。请先用少量、有备份的照片或视频验证流程，不要直接处理唯一副本。当前下载包使用 ad-hoc 签名且尚未公证，macOS 可能显示未知开发者警告。

[查看 Releases](https://github.com/EvanXuu/photoslim/releases) · [阅读产品需求](PRD-PhotoSlim.md) · [查看设计系统](PhotoSlim/DESIGN_SYSTEM.md)

## 为什么使用 PhotoSlim

- JPEG 转 HEIC，H.264 SDR 转 HEVC；也允许主动重压缩普通 `hvc1` HEVC 视频。
- 只使用公开的 PhotoKit、ImageIO、AVFoundation 和 VideoToolbox 接口，不直接修改 `.photoslibrary`。
- 下载、压缩和验证完成后先进入本地审核，不会边压缩边删除原件。
- 写入相册后再次核对关键元数据，删除原件仍由 Photos 显示系统确认。
- 记录已处理资产，避免同一项目被反复有损压缩。

## 0.1 Alpha 已实现

- 通过 PhotoKit 扫描照片、视频和收藏项目，并使用 persistent change token 增量更新索引。
- 支持网格/列表、搜索、筛选、排序、置顶、多选和空间预检。
- iCloud 原件最多 5 路并行下载，并与本机压缩流水线重叠；远端大小未知时不虚构估算值。
- 图片使用 HEIC；视频使用 VideoToolbox 手动参数，并以 `AVAssetExportSession` 作为兼容回退路径。
- 显示 iCloud 下载和压缩的独立进度；任务可最小化、排队、恢复或终止。
- 压缩结果先保存在本机网格中；点击可进入 100%–500% 缩放预览并拖动查看细节。
- 在结果网格中按住反斜杠 `\`，临时显示鼠标悬浮项目的原图；松开恢复压缩结果。
- 退出或崩溃后恢复未完成会话；终止任务会清理应用管理的临时文件。
- 独立统计页只累计已确认完成的任务，并显示本机存储空间。

## 安全工作流

```text
选择项目
   |
   v
空间预检 -> 最多 5 路 iCloud 下载 -> 本机压缩 -> 文件验证
                                          |
                                          v
                                  本地结果网格预览
                                      /       \
                                     v         v
                              撤回并清理    确认写入相册
                                                  |
                                                  v
                                      PhotoKit 创建/验证副本
                                                  |
                                                  v
                                      Photos 系统确认删除原件
```

“确认删除原件”通过 `PHAssetChangeRequest.deleteAssets` 把原件移到“最近删除”。PhotoSlim 不会清空“最近删除”，也不会绕过 Photos 的系统确认。审核阶段选择“撤回压缩副本”只会清理本地临时结果，原件保持不动。

## 支持范围

| 输入 | 输出 | 0.1 Alpha 状态 |
|---|---|---|
| 普通 JPEG | HEIC | 支持，验证尺寸与输出可解码性 |
| H.264 SDR 视频 | HEVC | 支持，手动码率或源文件比例 |
| 普通 `hvc1` HEVC | HEVC | 支持主动重压缩，并检查最低节省比例 |
| `hev1`、Dolby Vision、HDR、HEVC Alpha、混合轨道 | — | 默认排除 |
| iCloud 编码未知的视频 | 下载后确认 | 下载前显示为“编码待确认” |

PhotoSlim 会尽可能复制并验证拍摄日期、位置、收藏、隐藏状态、普通相簿关系和常见媒体元数据。由于 PhotoKit 公开 API 的限制，新建资产的添加日期和资产 ID 会变化；可逆编辑历史及人物关系不会复制。

## 下载与安装

1. 从 [GitHub Releases](https://github.com/EvanXuu/photoslim/releases) 下载 `PhotoSlim-0.1.0-alpha.1-macos.zip`。
2. 解压后把 `PhotoSlim.app` 移到 `/Applications`。
3. 首次启动时授予照片图库访问权限，并先用少量测试资产验证完整流程。

当前 Alpha 包使用 ad-hoc 签名且未经过 Apple 公证。macOS 可能阻止直接双击启动；如果你不信任预编译包，请检查源码并按下方步骤自行构建。稳定保留照片权限需要使用同一个 Apple Development 或 Developer ID 证书构建，仅保持 bundle ID 不足以保证 TCC 授权不重新询问。

## 系统要求

- macOS 14 或更高版本。
- 可读取和写入的 Apple 照片图库权限。
- 足够容纳所选 iCloud 原件、临时输出和安全余量的本机空间。
- 从源码构建需要 Xcode Command Line Tools 和 Swift 6 工具链。

## 从源码构建

调试构建：

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/photoslim-module-cache \
  xcrun swift build --disable-sandbox \
  --package-path PhotoSlim \
  --scratch-path /private/tmp/photoslim-build
```

测试：

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/photoslim-test-module-cache \
  xcrun swift test --disable-sandbox \
  --package-path PhotoSlim \
  --scratch-path /private/tmp/photoslim-test-build
```

生成 `.app` 和便携 ZIP：

```bash
PhotoSlim/Scripts/build-app.sh
```

默认输出到 `PhotoSlim/build/PhotoSlim.app` 和 `PhotoSlim/build/PhotoSlim.app.zip`。使用稳定证书签名：

```bash
PHOTOSLIM_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" \
  PhotoSlim/Scripts/build-app.sh
```

## 项目结构

```text
PhotoSlim/
|-- Sources/PhotoSlim/
|   |-- App/       AppModel、恢复与任务状态机
|   |-- Models/    资产、筛选、设置、会话和统计
|   |-- Services/  PhotoKit、压缩、磁盘预检和会话账本
|   |-- Theme/     颜色、间距和可复用样式
|   `-- Views/     浏览、任务、审核、队列、统计和历史
|-- Tests/         纯逻辑与程序生成媒体的编码测试
|-- Resources/     Info.plist、权限 entitlement 与 App Icon
`-- Scripts/       Release 打包与图标生成脚本
```

运行真实 PhotoKit 创建/删除流程会修改照片图库，因此自动化测试不会启动应用或删除真实资产，只覆盖纯逻辑、持久化和程序生成的临时媒体。

## 隐私与许可证

PhotoSlim 不包含遥测或云端服务，媒体处理在本机完成；只有 Photos/iCloud 自身可能产生网络流量。本仓库目前未附带开源许可证，源码公开用于审阅，但默认保留所有权利。
