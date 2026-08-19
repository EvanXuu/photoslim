# PhotoSlim Design System

这是 PhotoSlim 的正式设计依据。未来页面、组件和交互必须复用这里的语义 token 与行为，不得另起一套视觉语言。

## 1. 项目概览

- 产品：PhotoSlim。
- 类型：原生 macOS 照片生产力工具；App/Product UI + Native Desktop。
- 平台：macOS 14 及以上，SwiftUI。
- 用户：拥有大型 Apple/iCloud 照片图库、重视隐私与可逆操作的 Mac 用户。
- 主目标：让大批量有损压缩像一套可检查、可中断、可恢复的暗房工作流程，而不是危险的“一键清理”。

## 2. 品牌方向

- 视觉风格：温暖、克制、原生、工具化。
- 情绪：安静可信，强调核对和事务状态，不制造空间焦虑。
- 设计概念：“相片暗房里的检查台”——暖灰工作台承载真实照片，深墨文字负责精确说明，单一琥珀信号标记正在进行或需要用户决定的动作。
- 文案：直接说明动作及其对象。主按钮使用“检查空间并开始”“加入准备队列”“确认删除原件”等单一动词意图；错误说明发生了什么、原件是否安全、下一步是什么。面向用户的文案不暴露 PhotoKit、资源读取、sample entry、内部校验或编码器实现；格式、空间、风险和下一步仍要说清楚。
- 对抗审查：遮住产品名后，暖灰检查台、单一琥珀事务信号和“先验证、后决定”的强制审核仍能区分普通照片管理器。初版弱点是浅/深模式共用的橙色无法同时满足按钮文字与暗色背景对比度；已改成动态琥珀色与动态按钮前景。
- 参考：
  - [Apple macOS design](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)：原生窗口密度、工具栏和键盘习惯。
  - [Apple sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)：稳定的图库/工作区一级导航。
  - [Apple typography](https://developer.apple.com/design/human-interface-guidelines/typography)：系统字体和信息层级。
  - [Apple Photos browse guide](https://support.apple.com/guide/photos/browse-your-photo-library-pht53854a251/mac)：熟悉的网格/列表浏览方式。
  - [Pixelmator Pro interface](https://support.apple.com/en-ca/guide/pixelmator-pro/pix96e754af4/mac)：照片优先的画布与可收起工具。

## 3. 颜色系统

颜色在代码中集中于 `PhotoSlimTheme`，禁止在功能页面引入新的品牌色。

| 角色 | 浅色 | 深色 | 用途 |
|---|---:|---:|---|
| Canvas 60% | `#F3F0E9` | `#131313` | 页面大背景 |
| Surface 30% | `#FBFAF5` | `#1D1D1D` | 侧栏、页头、主面板 |
| Raised surface | `#FFFFFF` | `#292929` | 当前项目、输入和浮层 |
| Ink | `#1B1A18` | `#F0F0F0` | 主文字 |
| Signal 10% | `#B9570F` | `#DE8436` | 主操作、进度、选中和待决状态 |
| Signal foreground | `#FFFFFF` | `#131313` | Signal 实心控件文字/图标 |
| Success / warning / danger | macOS semantic green/orange/red | macOS semantic green/orange/red | 必须同时带图标或标签 |
| Hairline | 当前主文字 11% alpha | 当前主文字 11% alpha | 原生列表分隔与面板轮廓 |

规则：大面积只使用 Canvas/Surface；Signal 不做装饰背景。卡片通过背景层级和 1 px 原生 hairline 区分，不使用彩色装饰边框。浅色 `Ink/Canvas` 对比度 15.28:1，`Ink/Surface` 16.64:1，白字/浅色 Signal 4.74:1；深色 `Ink/Canvas` 16.30:1，`Ink/Surface` 14.79:1，深色 Signal/Canvas 6.60:1。系统 secondary label 由 AppKit 按外观适配。

## 4. 字体系统

- 字体：SF Pro（`Font.system`）用于界面；SF Mono（system monospaced design）只用于字节、百分比和进度数字。
- 性格：中性精确，符合 macOS 工具，不引入品牌展示字体。
- 层级：Display 26/semibold；H1 24–25/semibold；H2 19–20/semibold；H3 15–17/semibold；Body 13–14/regular；Body small 11–12/regular；Caption 9–10/regular；Button 13/semibold。
- 行高：多行说明使用约 1.4；正文每行建议不超过 70 个中文字符。
- 数字：空间、比例和进度使用等宽数字，避免任务运行时布局跳动。
- 文本不得烘焙进图片。关键警告不可截断；文件名可单行截断并通过辅助功能朗读完整值。

## 5. 布局系统

- 窗口最小尺寸：980 x 660 pt；内容使用可增长布局，不设固定最大窗口。
- 侧栏：理想 224 pt，可在 224–260 pt 之间调整。
- 内容边距：20–24 pt；组件紧凑间距 8 pt；区段间距 18 pt。
- 网格：自适应 174–230 pt，每格 12 pt 间距；缩略图固定 4:3 视觉窗并以 aspect-fit 完整显示，不裁切原图。
- 浏览 Toolbar：搜索、筛选、排序、列表/网格切换、全选/取消全选和扫描变更集中在窗口顶部，使用 Finder 风格的原生 Toolbar 控件；使用原生窗口标题显示当前媒体类型，使用原生窗口副标题显示项目数量，避免将标题放入 Toolbar 气泡；列表和网格都支持通过上下文菜单置顶，置顶项目稳定排在当前排序之前。
- 页面结构：侧栏 -> 顶部 Toolbar -> 主数据视图 -> 选择条。处理页和审核页临时替代主数据视图。
- 选择条：选中后只显示已知原件大小、已知 iCloud 下载大小、任务安全余量和本机可用于任务的空间；不生成输出大小或节省空间预测，容量校验结果不得延迟到开始按钮之后。
- iCloud 项目在下载前不估算原件、输出或节省空间；资源 `dataSize` 已知时直接显示原件大小，未知时不渲染大小文本。资源状态明确区分“本地可用”“需要 iCloud 下载”和“状态未知”；开始任务后通过 `PHAssetResourceManager` 获取目标原件，显示独立下载进度，完成才读取真实文件大小，并用真实输出大小复核压缩率。
- 主流程：浏览/筛选 -> 选择 -> 空间预检 -> 最多 5 路 iCloud 下载/处理 -> 本地结果预览 -> 用户确认写入 -> 强制审核/系统删除 -> 两种终局之一。
- 模态：详细设置和空间预检使用 sheet；排除项与撤回风险由应用说明；最终删除直接使用 PhotoKit 触发的 Photos 系统确认，不叠加应用内 alert；处理可以收为右下角非模态浮窗。
- 小窗口：网格自动减列；列表和底部选择条保留横向最小信息，不隐藏安全动作。

## 6. 组件系统

- 基础：纯 SwiftUI/AppKit 语义控件，不混用第三方 UI 库。
- 主按钮：`SignalButtonStyle`，最小高度 32 pt、9 pt 圆角、13 pt semibold；disabled 36% opacity；按下 82% opacity。
- 次按钮：系统 bordered/plain 样式。破坏性按钮必须使用明确的删除动词；删除原件依赖 Photos 系统确认，应用不再额外二次提醒。
- 面板：`InsetPanelModifier`，Surface 背景、16 pt 圆角、1 px hairline。
- 资产卡：12 pt 圆角；选中用 Signal 轮廓和浅 Signal 背景；不可处理项降低不透明度并显示锁。
- 标签：只表示格式、云端、时长或事务状态，不使用营销型胶囊。
- 表单：系统 Form、Picker、Slider、Stepper、TextField、Toggle、DatePicker；视频参数先显示“自动/手动”，自动时只保留选择项，手动模式再按“分辨率 × 帧率码率表 -> 速率上限 -> 关键帧/帧重排 -> 音频”排列，帮助文字紧邻对应设置。
- 进度：全局进度一条；当前项固定展示“下载原件”和“照片压缩/视频压缩”两条独立进度。
- 视频编码：普通 SDR H.264 和普通 hvc1 HEVC 默认走 AVAssetExportSession 的 HEVC 预设；用户在视频详细设置中显式切换手动后，才使用 AVAssetReader/AVAssetWriter 配合 VideoToolbox 控制 HEVC 码率。手动码率表按 1080p/2160p/4320p 与 30/60 fps 编辑，非标准尺寸按像素数插值；HDR、定时元数据或手动管线不适配时仍使用兼容预设。共享的 HEVC 硬件能力模块最低支持 iOS 15，桌面 UI 仍支持 macOS 14+。
- 数据状态：每个数据页都有空、加载、失败状态；失败文案同时给出原件安全状态。
- 图表：统计页使用原生几何条形，不引入图表库；顶部先显示本机存储容量与当前选择占用，再显示累计节省。

## 7. 卡片与区段

- 风格：扁平、轻分层、无装饰渐变。
- 圆角：控件 9 pt，卡片 12 pt，面板 16 pt。
- 阴影：常规内容无阴影；仅右下角任务浮窗使用黑色 18% / radius 18 / y 7，表达窗口叠放。
- 材质：仅任务浮窗使用 `regularMaterial`；其他区域使用不透明语义 surface。
- 禁止多层卡片套卡片；详情展开使用分隔线和 raised surface。

## 8. 图标系统

- 图标：仅 SF Symbols。
- 尺寸：行内 9–12 pt，控件 14–18 pt，空状态/授权 30–38 pt。
- 颜色：默认 secondary；主要动作 Signal；成功/警告/失败使用系统语义色并配文字。
- 纯图标按钮必须提供 `.help` 或 accessibility label；不可只靠颜色传达状态。

## 9. 图片与资产

- App icon：代码生成的多尺寸 PNG Asset Catalog；暖灰照片卡、深墨取景窗和向内的琥珀压缩标记，不使用文字或 SF Symbols。窗口内品牌名仍采用系统文字。
- 主图：只显示用户通过 PhotoKit 授权的真实缩略图，不使用库存图或 AI 生成图。
- 缩略图：网格使用 4:3 容器、列表使用 44 x 44 pt 容器，图片统一 aspect-fit 完整显示，空余区域使用 raised surface，不允许裁切填满；9/6 pt 圆角；云端原件不可用时显示类型占位符，且不会为缩略图触发 iCloud 下载。
- 隐私：空状态、文档、遥测和日志不得包含真实缩略图、文件名、位置或 PhotoKit 资产 ID。

## 10. 动效与交互

- 框架：SwiftUI 原生动画，无第三方动效库。
- 允许的动效：任务浮窗展开/收起使用 180 ms ease-in-out 的位移+透明度；系统 sheet、popover、alert 沿用 macOS 动效。
- 禁止：自动轮播、装饰粒子、长时间弹跳和会掩盖事务状态的过渡。
- Hover/focus/pressed/disabled：使用系统 hover/focus ring；Signal 按钮提供 pressed/disabled 状态；列表整行有明确 content shape。
- 异步反馈：长任务使用可量化进度和当前文件；系统事务使用 spinner + 状态句；错误用 alert 或行内失败状态。
- 结果预览：结果网格使用本地临时输出；点击进入可缩放、可拖动的单项预览。网格中键盘反斜杠只作用于鼠标悬浮的卡片，按住临时显示对应原图，松开立即恢复压缩结果；快捷键事件由预览层消费，不触发系统提示音。
- Reduced Motion：主要工作流不依赖动效；系统开启减少动态效果后即使取消浮窗过渡也不影响信息和操作。
- 性能：缩略图按可见区域懒加载，列表使用 Lazy 容器；首次索引串行读取本地原件，后续通过 persistent change token 仅串行读取变更项目；压缩串行导入 PhotoKit，避免内存和磁盘峰值。

## 11. 可访问性

- 对比度：正文至少 4.5:1，大图标/控件至少 3:1；浅色和深色主题分别计算。动态 Signal 前景不可被固定白色替代。
- 键盘：系统控件保留 focus ring 和标准 Tab 顺序；默认/取消按钮使用 Return/Escape；Command-R 扫描图库变更。
- 语义：资产卡提供完整 accessibility label/value；状态同时使用图标、文字和颜色。
- 文本：警告允许换行；关键删除按钮不使用模糊的“继续/确定”。
- 系统适配：支持浅色/深色、Increase Contrast 的系统语义色与 Reduce Motion；在 macOS 显示缩放和 VoiceOver 下必须保持核心流程可用。

## 12. 项目专属反模板规则

- 允许颜色仅为 `#F3F0E9`、`#FBFAF5`、`#FFFFFF`、`#1B1A18`、`#B9570F`、`#131313`、`#1D1D1D`、`#292929`、`#F0F0F0`、`#DE8436` 及 macOS success/warning/danger 语义色。
- 纯黑不使用；纯白只作为浅色 raised surface 和浅色 Signal 前景。
- 不使用紫色渐变、巨大标题、欢迎仪表盘、随机 KPI 卡、营销式毛玻璃或无意义胶囊。
- “统计”是独立用户请求页面；不得把累计节省卡塞回图库首页。
- 原生 hairline 和列表 Divider 是桌面数据密度的明确例外，不应被误删为“装饰边框”。

## 13. 未来页面规则

未来页面必须复用相同颜色、SF 字体层级、20–24 pt 页面边距、SF Symbols、Signal 主操作和事务文案。新功能应先决定它属于“浏览准备”“执行进度”“强制审核”还是“历史统计”，再进入对应现有页面，不增加平行首页。

## 14. 更新策略

任何颜色、字体、间距、组件、动效、图标、缩略图或关键安全交互变化，都必须与代码在同一次提交中更新此文件。设计系统与真实界面不一致视为缺陷。

用户可见文案变化同样需要同步更新本文件：技术实现只留在代码和开发文档中，界面只保留用户做选择所需的事实、风险与下一步。
