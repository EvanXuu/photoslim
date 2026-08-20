# PhotoSlim

PhotoSlim 是一款同时提供 macOS 与 iOS 客户端的原生 Apple 照片压缩工具。在修改照片图库前，它会先把压缩结果保存在本机，完成文件验证，并让你逐项对比原件。

> **0.2beta**：这是面向小规模、有备份图库测试的早期版本。请不要直接处理重要媒体的唯一副本。下载包使用 ad-hoc 签名且尚未公证，macOS 可能显示未知开发者警告。

[English](README.md) · [查看 Releases](https://github.com/EvanXuu/photoslim/releases) · [阅读产品需求](PRD-PhotoSlim.md) · [查看设计系统](PhotoSlim/DESIGN_SYSTEM.md)

## 功能概览

- 将普通 JPEG 照片转换为 HEIC，将 SDR H.264 视频转换为 HEVC。
- 允许用户主动重新压缩普通 `hvc1` HEVC 视频。
- 视频默认使用 AVAssetExportSession 的自动 HEVC 路径；进入详细设置后可切换手动码率表。
- 只显示 Photos 已提供的原始资源大小；iCloud 大小未知时留空，不虚构估算值。
- 最多同时下载 5 个 iCloud 原件，并与本机压缩流水线重叠。
- 先在本机预览压缩结果，再写入 Photos。
- 点击结果可进入详情查看；按住反斜杠键可对比鼠标悬浮项目的原图。
- 先写入并验证压缩副本，最后才由 Photos 确认将原件移到“最近删除”。

## 0.2beta 重点

- 新增“先审核、后写入”的完整流程：下载、压缩、查看、对比，确认后才写回 Photos。
- iCloud 最多 5 路并行下载，并分别显示下载和压缩进度。
- 支持普通 `hvc1` HEVC 主动重压缩；Dolby Vision、HDR、`hev1`、HEVC Alpha 和混合轨道仍保守排除。
- 手动视频模式提供可编辑的 1080p、2160p、4320p 及 30/60 fps 码率表；标准分辨率允许 1 像素偏差，非标准分辨率按像素数量给出推荐值。
- 使用原生 macOS 窗口标题和副标题显示当前媒体类型及项目数量，不再额外叠加标题气泡。
- 扫描和选择阶段不显示预计输出大小或预计节省；只有实际压缩并验证完成后才记录真实节省空间。
- 新建或未被用户修改过的旧设置默认使用 8% 最低实际节省比例。
- macOS 排序按钮会直接列出所有排序方式；图库底栏常驻显示设备可用空间与总容量。
- 空间和安全余量在任务开始时于后台校验，不再展示独立预检。iPhone 选中项目后，四个工作区会暂时替换为包含状态、参数和下一步操作的胶囊栏。

## 安全流程

1. 选择项目。
2. PhotoSlim 在后台检查空间，最多并行下载 5 个 iCloud 原件，压缩并验证文件。
3. 在本机审核结果，可撤回并清理，或确认写入。
4. PhotoSlim 创建并验证 Photos 副本。
5. Photos 显示系统确认，将原件移到“最近删除”。

PhotoSlim 不直接修改 `.photoslibrary` 文件包，只使用公开的 PhotoKit、ImageIO、AVFoundation 和 VideoToolbox 接口。扫描、下载、压缩和审核期间原件保持不变。

## 支持范围

| 输入 | 输出 | 0.2beta 状态 |
| --- | --- | --- |
| 普通 JPEG | HEIC | 支持，验证尺寸与可解码性 |
| SDR H.264 视频 | HEVC | 支持，默认使用自动导出 |
| 普通 `hvc1` HEVC 视频 | HEVC | 支持主动重压缩，需明确加入任务 |
| `hev1`、Dolby Vision、HDR、HEVC Alpha、混合轨道 | — | 保守排除 |
| 编码未知的 iCloud 视频 | — | 下载原件后再确认编码 |

PhotoSlim 会尽可能复制并验证 PhotoKit 能提供的新资产元数据，包括拍摄日期、位置、收藏、隐藏状态和普通相簿关系。新建资产的 ID 和添加日期必然变化；编辑历史及人物关系不会复制。

## 下载与安装

1. 从 [0.2beta Release](https://github.com/EvanXuu/photoslim/releases/tag/v0.2beta) 下载 `PhotoSlim-0.2beta-macos.zip`。
2. 解压后将 `PhotoSlim.app` 移动到 `/Applications`。
3. 首次启动时授予照片图库权限，并先使用少量测试项目。

预编译包使用 ad-hoc 签名且未经过 Apple 公证。若 macOS 阻止首次启动，请确认来源后在 Finder 中右键选择“打开”。要在更新二进制文件后稳定保留照片权限，需要使用同一个 Apple Development 或 Developer ID 证书构建；仅保持 bundle ID 不足以保证 TCC 身份不变。

## 系统要求

- macOS 14 或更高版本。
- iPhone 目标最低支持 iOS 17。
- 已允许读取和添加 Apple 照片图库。
- 有足够空间容纳所选 iCloud 原件、临时输出和安全余量。
- 从源码构建需要 Xcode Command Line Tools 和 Swift 6 工具链。

包中已加入最低 iOS 17 的 SwiftUI 目标。它直接复用 macOS 应用的 AppModel、PhotoKit 扫描、空间检查、压缩、队列、会话恢复、统计、历史及审核写回流程；iPhone 端只单独适配原生导航和触控界面，包括左上角媒体类型、右上角筛选与更多、下拉搜索和四个底部工作区。选中任意项目后，工作区栏会暂时替换为胶囊状态栏；iOS 26 使用原生 Liquid Glass，iOS 17–25 使用系统材质回退。

## 从源码构建与测试

调试构建：

~~~
xcrun swift build --disable-sandbox --package-path PhotoSlim --scratch-path /private/tmp/photoslim-build
~~~

测试：

~~~
xcrun swift test --disable-sandbox --package-path PhotoSlim --scratch-path /private/tmp/photoslim-test-build
~~~

生成 `.app` 和便携 ZIP：

~~~
PhotoSlim/Scripts/build-app.sh
~~~

默认输出到 `PhotoSlim/build/PhotoSlim.app` 和 `PhotoSlim/build/PhotoSlim.app.zip`。使用稳定证书签名时，请在运行脚本前设置 `PHOTOSLIM_SIGNING_IDENTITY`。

构建并打包通用 iOS 模拟器应用：

~~~
PhotoSlim/Scripts/build-ios-simulator-app.sh
~~~

模拟器 ZIP 输出到 `PhotoSlim/build/PhotoSlim-iOS-Simulator.app.zip`；供 `simctl` 直接安装的签名 `.app` 默认位于 `/private/tmp/PhotoSlim-iOS-Simulator-build`。

## 隐私与许可证

PhotoSlim 不包含遥测或云端服务，媒体处理在本机完成；只有 Photos/iCloud 自身可能产生网络流量。本仓库目前未附带开源许可证，源码公开用于审阅，但默认保留所有权利。
