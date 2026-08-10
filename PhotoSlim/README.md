# PhotoSlim

PhotoSlim 是一个原生 macOS 14+ 照片与视频压缩应用。它通过公开的 PhotoKit、ImageIO 和 AVFoundation 接口，把普通 JPEG 转换为 HEIC、把 H.264 SDR 或普通 hvc1 HEVC 视频转换为 HEVC，并在删除任何原件前建立可恢复的审核会话。

当前 bundle ID 固定为 `local.codex.PhotoSlim`。后续版本只更新版本号，不更换 bundle ID。

## 已实现

- 读取 Apple 照片图库，识别本地原件与需要 iCloud 下载的项目。
- 首次扫描建立持久索引；以后使用 PhotoKit change token 只重扫新增或修改项目并移除已删除项目，token 失效时也只做轻量元数据比对。
- 已确认完成的原资产与压缩副本写入处理账本，默认隐藏并硬性禁止再次有损压缩。
- 侧栏负责照片/视频/收藏图库类型；筛选菜单提供 1/3/5 年以上、10 MB/100 MB/1 GB 以上、自定义门槛、手动范围、收藏和本地/iCloud 条件。
- 默认折叠的排除项；编码待确认的 iCloud 视频默认显示，下载后强制验证；其他排除项取消前显示原因和风险。
- 按预计节省、比例、大小、日期、时长和文件名排序；支持资产置顶，置顶项目始终位于当前排序之前。
- 网格/列表切换、完整不裁切的 PhotoKit 缩略图和多选。
- 搜索、筛选、排序、列表/网格切换和全选都位于 Finder 风格的窗口顶部 Toolbar；“全选”再次点击会变为“取消全选”。
- 推荐值只是填写起点；视频使用手动 VideoToolbox 参数，可选择源文件比例或固定平均码率，并设置视频硬上限、关键帧间隔、帧重排和音频策略。
- 每次勾选都立即计算已知本地输入体积、可计算的预计节省和临时空间；空间不足时拒绝新选择，“全选”只保留已知空间允许的项目。
- 本地资产按 PhotoKit 资产标识去重；macOS 27+ 在 PhotoKit 已知资源大小时读取 `PHAssetResource.dataSize`。iCloud 原件在下载前不按分辨率、时长或码率估算，列表显示“下载后读取”；下载后才写入精确字节数。
- iCloud 下载与 HEIC/HEVC 压缩独立进度。
- 最多同时下载 5 个 iCloud 原件，并与当前项目的压缩流水线重叠；不把整批原件载入内存。
- 任务页可缩为右下角浮窗；同时可准备下一批并加入持久化队列。
- 压缩后先把结果保存在应用临时目录，进入本地网格预览；点击可打开单项预览，按住“查看原图”或键盘反斜杠可做 Before/After 对比。
- 用户确认结果后，才导入并核对尺寸/时长/拍摄日期/位置/收藏/隐藏状态，再调用 Photos 的系统确认删除原件。
- 任务处理中可终止；会取消下载/转码并清理临时文件，不删除原件或已经写入相册的资产。
- 只能选择“撤回压缩副本”或“确认删除原件”；审核前不会删除原件。确认删除时直接使用 Photos 的系统提示，不再叠加应用内二次确认。
- 未完成会话、工作文件和队列写入 Application Support，崩溃或重启后恢复。
- 未完成任务退出时执行两次确认。
- 独立统计页，只累计已确认删除原件的任务，并显示本机总容量、已使用、立即可用及可用于任务的空间。

## 安全事务

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

“确认删除原件”只通过 `PHAssetChangeRequest.deleteAssets` 移到“最近删除”；新流程的“撤回压缩副本”只清理尚未写入相册的本地临时结果，旧版已创建的副本才会通过 PhotoKit 移到“最近删除”。应用不会清空“最近删除”，也不会声称能自动恢复其中的资产。

## 支持范围与公开 API 限制

首版处理普通 JPEG、H.264 SDR，以及明确识别为普通 hvc1 sample entry 的 HEVC 视频。hvc1 会标注为 HEVC→HEVC 再编码，仍须通过最低节省比例、输出可解码性、尺寸和时长验证；hev1、Dolby Vision、HDR、HEVC Alpha 和混合轨道继续锁定。本地视频会遍历所有视频轨道及 Photos 组合资产的源片段。云端视频在下载前无法确认内部编码，因此归入“编码待下载确认”并默认显示，下载后强制验证。

在旧版 macOS 或 Photos 尚未解析资源时，公开 PhotoKit 可能无法提供 iCloud 远端原件的精确字节数；macOS 27+ 会在 `PHAssetResource.dataSize` 已知时显示该值。未知云端大小不再使用码率模型或其他保守估算，也不计入开始前的压缩率统计。任务下载后读取真实输入文件大小，压缩完成后读取输出文件大小，再检查最低节省比例；若空间或节省比例不满足要求，任务安全失败并保留原件。

视频编码采用双路径：普通 SDR H.264 和普通 hvc1 HEVC 默认使用 `AVAssetReader/AVAssetWriter + VideoToolbox` 手动控制码率；HDR、定时元数据或手动管线拒绝样本时使用 `AVAssetExportSession` 的可用 HEVC 预设。iOS 共享媒体能力模块的最低部署版本为 iOS 15，当前 PhotoSlim 图形界面仍为 macOS 14+。

新建 PhotoKit 资产会改变以下信息，公开 API 无法避免：

| 字段 | 结果 |
|---|---|
| 拍摄日期、位置、收藏、隐藏、普通相簿关系 | 复制并验证 |
| 图片 EXIF/IPTC、视频 QuickTime 全局元数据 | 尽可能复制并做输出验证 |
| 像素尺寸、视频方向、时间轴、时长 | 保持并验证 |
| 添加日期、PhotoKit 资产 ID | 会变化 |
| 可逆编辑历史、人脸/人物关系 | 不复制；相关资产默认锁定 |

## 构建

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

生成签名 `.app`：

```bash
PhotoSlim/Scripts/build-app.sh
```

默认使用 ad-hoc 签名并输出 `PhotoSlim/build/PhotoSlim.app` 与 `PhotoSlim/build/PhotoSlim.app.zip`。若项目位于 iCloud Drive 或其他 File Provider 目录，请优先解压 ZIP 后把应用移到 `/Applications`；这可以避免同步服务附加的 Finder 扩展属性干扰代码签名检查。为了让照片授权在应用更新后稳定保留，请使用同一个 Apple Development 或 Developer ID 证书构建：

```bash
PHOTOSLIM_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" \
  PhotoSlim/Scripts/build-app.sh
```

仅保持 bundle ID 和版本号稳定并不足以保证 ad-hoc 二进制更新后的 TCC 授权不重验；稳定签名的 designated requirement 才是关键。

重新生成应用图标源文件：

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/photoslim-icon-module-cache \
  xcrun swift PhotoSlim/Scripts/generate-app-icon.swift \
  PhotoSlim/Resources/Assets.xcassets/AppIcon.appiconset
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
|-- Tests/         纯逻辑测试与程序生成媒体的编码集成测试
|-- Resources/     Info.plist、照片权限 entitlement 与 App Icon
`-- Scripts/       Release .app 打包与可重建图标脚本
```

运行或测试 PhotoKit 创建/删除流程会修改真实照片图库，因此自动化测试只覆盖纯逻辑、持久化和程序生成的临时 JPEG/H.264 样片，不会启动应用或触发照片修改。
