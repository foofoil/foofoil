# 浮箔 foofoil

**给你的桌面降维。**
**Anything, right where you need it.**

[English](README.md)

浮箔是一款轻量级 macOS 悬浮参考应用。它可以把图片、视频、音频、文档、笔记和网页内容放在极简悬浮窗口中，让参考资料在工作时始终触手可及。

「浮箔」之名取自内容在桌面上的存在方式：它们像一张张轻薄的箔片，浮在工作区中，需要时触手可及，又尽可能不带来传统窗口的视觉负担及复杂的操作逻辑。

“箔”的意象也来自刘慈欣《三体》中的“二向箔”——将复杂的世界压成轻薄的一层。于是有了浮箔的 slogan：**给你的桌面降维。**

浮箔使用 SwiftUI 与 AppKit 构建，优先利用 macOS 原生能力，追求快速、自然的交互和尽可能少的依赖。

## 功能特性

- 打开多个相互独立的悬浮窗口。
- 将窗口置于其他应用之上，调整其透明度，并显示或隐藏边框。
- 在多显示器间拖动、调整大小、缩放和定位窗口。
- 打开图片、视频、音频、Hi-Fi 音频、EPUB 电子书、PDF、纯文本、Markdown、CSV、HTML 和网站。
- 直接从剪贴板粘贴或打开图片。
- 通过内嵌的 macOS Quick Look 预览其它本地文档（如 Office、富文本）；实际预览能力取决于系统及已安装的 Quick Look 预览器。
- 预览 Markdown、以表格方式浏览 CSV 数据，并导航 PDF 页面。
- 缩放图片和网页内容、让图片适应窗口，以及自定义 SVG 颜色或文档样式：为纯文本、Markdown、电子书调整内容背景色、文字颜色、字体、行间距与段落间距（随系统明暗切换自动适配深浅）。
- 使用 macOS 原生工作流保存、复制、分享或截取显示的内容。
- 恢复窗口状态，并在本地保存内容历史。
- 按标题和内容搜索历史记录，包括使用设备端 OCR 识别图片，以及提取 PDF 和网页文本。
- 通过 ⌘P 搜索历史及已授权文件夹中的本机文件名，复用 Spotlight 索引。
- 在设置中自定义快捷键；支持英文与简体中文界面。

Hi-Fi 当前支持 DSF、raw DFF、未压缩立体声 SACD ISO 和 APE/CUE。DSD 播放要求支持 DoP 的输出设备，不提供 DSD 转 PCM 回退；DST 与 SACD 多声道尚不支持。EPUB 支持目录导航和阅读位置恢复，不支持 DRM 加密书籍。

## 轻量化设计

浮箔尽可能直接使用 macOS 已经提供且足够成熟的系统能力，而不是随应用重复携带浏览器引擎、语言运行时或大型通用媒体框架。“轻量”是一项实现原则：控制依赖、复用原生能力，不重复携带系统已经提供的基础设施。

## 快速开始

启动浮箔后，可以通过以下任一方式添加内容：

- 将支持的文件、图片或文本拖放到浮箔窗口。
- 选择“文件 > 打开”（<kbd>⌘ O</kbd>）来打开本地文件。
- 选择“文件 > 打开 URL”（<kbd>⌘ L</kbd>）来显示网页。
- 选择“文件 > 打开剪贴板图片”（<kbd>⇧ ⌘ V</kbd>）来创建图片参考窗口。
- 在空白窗口中直接输入，将其作为便笺使用。

右键单击窗口，可以访问与当前内容最相关的操作。

## 常用快捷键

| 操作 | 快捷键 |
| --- | --- |
| 新建浮箔窗口 | <kbd>⌘ N</kbd> |
| 打开文件 | <kbd>⌘ O</kbd> |
| 打开 URL | <kbd>⌘ L</kbd> |
| 打开剪贴板图片 | <kbd>⇧ ⌘ V</kbd> |
| 搜索历史记录与文件 | <kbd>⌘ P</kbd> |
| 切换置顶 | <kbd>⌘ T</kbd> |
| 切换边框 | <kbd>⌘ B</kbd> |
| 放大/缩小内容 | <kbd>⌘ +</kbd> / <kbd>⌘ −</kbd> |
| 增大/缩小箔 | <kbd>⇧ ⌘ +</kbd> / <kbd>⇧ ⌘ −</kbd> |
| 打开设置 | <kbd>⌘ ,</kbd> |
| 恢复内容实际大小 | <kbd>⌘ 0</kbd> |
| 重置当前窗口 | <kbd>⌘ K</kbd> |
| 关闭当前窗口 | <kbd>⌘ W</kbd> |
| 增加/降低不透明度 | <kbd>⇧ ⌘ ↑</kbd> / <kbd>⇧ ⌘ ↓</kbd> |

以上为默认快捷键，可在设置中调整。更多与内容类型及窗口位置相关的快捷键可以在 macOS 菜单栏中查看。

## 从 Finder 用快捷键打开

将浮箔放入“应用程序”文件夹并启动一次。在 Finder 选中文件或文件夹，选择“Finder → 服务 → 在浮箔中打开”，即可在新箔片中打开；支持多选，文件夹沿用拖放时的扫描和分组规则。

在“系统设置 → 键盘 → 键盘快捷键 → 服务”中找到“在浮箔中打开”，启用并设置一个未被 Finder 占用的快捷键。之后选中项目按该快捷键即可。服务首次安装后若未出现，可退出并重新登录 macOS 后再检查。

## 系统要求

- macOS 26.5 或更高版本，与项目当前的部署目标一致
- 支持项目所配置 macOS SDK 的 Xcode 版本

## 从源码构建

完整开发环境使用以下兄弟仓库布局。`extension-kit` 是工程必需的本地 Swift 包；`hifi` 和 `ebook` 提供随应用交付的音频与 EPUB 能力。

```text
workspace/
├── foofoil/        # 应用、窗口、内容展示与搜索
├── extension-kit/  # 内部模块契约与测试
├── hifi/           # Hi-Fi 音频实现
└── ebook/          # EPUB 解析与阅读
```

推荐在 `foofoil` 仓库运行：

```sh
./run
```

脚本构建 Debug 应用、构建并嵌入相邻仓库的 Hi-Fi 和 EPUB 模块，然后重启浮箔。缺少对应 `build-plugin` 脚本时会跳过该模块，相关内容能力不可用。

1. 使用 Xcode 打开 `foofoil.xcworkspace`，以便同时编辑应用和相邻模块。
2. 选择 `foofoil` Scheme 和 **My Mac** 运行目标。
3. 如果 Xcode 提示签名问题，请配置开发者签名团队。
4. 使用 `./run` 验证完整内容能力；Xcode 的 ⌘R 不会执行相邻模块的构建与嵌入。

仅构建主应用（不嵌入相邻模块）：

```sh
xcodebuild build \
  -project foofoil.xcodeproj \
  -scheme foofoil \
  -configuration Debug \
  -destination 'platform=macOS'
```

运行测试：

```sh
xcodebuild test \
  -project foofoil.xcodeproj \
  -scheme foofoil \
  -destination 'platform=macOS'
```

## 开发模块与产品交付

扩展/插件仅作为开发阶段拆分、联调和验证能力的手段。最终产品不提供扩展概念：Hi-Fi、EPUB 等是浮箔自身的内容能力，用户无需单独安装、启用或更新插件。

当前源码仍保留 `ExtensionSupport`、C ABI、Manifest 和 `.foofoilextension` 等内部名称及管理实现。统一的内部产品开关隐藏管理界面、停止启动更新检查并禁用安装提示；加载与管理代码保留，便于未来重新启用。职责边界与历史方案的适用范围见[开发说明](docs/extension-support.zh-CN.md)。

分发脚本 `./package-dmg` 会构建 Release 应用，将 Hi-Fi 和 EPUB 模块一起嵌入并生成 DMG。完整打包需要上述四个仓库。可用 `./package-dmg --no-sign` 生成本地验证包；正式签名与公证使用 `./package-dmg --sign`，需配置 Developer ID 和 notarytool 凭据（见脚本头部）。

## 技术实现

浮箔主要使用 SwiftUI 实现界面，并通过 AppKit 实现原生悬浮窗口、菜单、文本控件和视觉效果。内容展示与搜索功能使用了 WebKit、PDFKit、Vision、AVFoundation、CoreAudio、ImageIO、Uniform Type Identifiers 和 SQLite3 等 Apple 框架。Markdown 渲染使用项目现有的内置 cmark 库。

历史记录和缓存内容保存在用户的 Application Support 目录中。OCR 与内容索引均在本机完成；网页及其远程资源的加载需要网络连接。

## 开发原则

- 保持应用轻量、快速响应。
- 优先使用 macOS 系统框架和项目已有组件。
- 避免引入重量级或不必要的第三方依赖。
- 保持原生 macOS 交互、无障碍支持和本地化完整性。
- 保证当前版本的窗口恢复与会话重建，保护用户拥有的文件；未发布开发数据不承诺跨版本兼容。

完整的贡献与实现规范请参阅 [AGENTS.md](AGENTS.md)。

## 参与贡献

欢迎参与浮箔的开发。提交更改前请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

浮箔使用 [MIT License](LICENSE)，版权所有 © 2026 北京记忆视界科技有限公司。

应用内置的 cmark 库使用其自身的宽松开源许可证，所需声明请参阅 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
