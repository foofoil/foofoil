# 只读代码着色：JavaScript＋系统 WKWebView 实现方案

日期：2026-10-15  
状态：待实施；本文只描述方案，不包含功能代码。  
基准：本地 main，`3ff5544032ae586be7d34a37ddf5c374e2e82e55`。原生 Tree-sitter 实验保留在 `readonly-code-highlighting`，不作为本方案的代码依赖。

## 1. 决策与目标

对已知语言的只读代码文件，使用随应用打包的 highlight.js，在系统 WKWebView 中显示高亮结果。普通只读文本继续使用 NSTextView。应用始终离线处理代码；无需服务器、CDN、浏览器引擎副本或额外安装步骤。

优先压低安装包增量，同时保留现有文档字体、字号、颜色、间距、滚动和选择复制行为。接受 WebKit 的进程与初始化开销，但必须测量多窗口场景的实际成本。只读场景不需要增量解析、编辑器、LSP、代码补全、Neon 或 Tree-sitter。

本次方案明确选择 WKWebView 展示；JavaScriptCore＋NSTextView 是另一条路线，不在实施范围内。不会为了语法着色把原本的文本内容状态改成网页状态。

## 2. 范围

首版直接打包 highlight.js 11.12.0 的 **全部 193 个内置语法模块**，另加 `highlightjs-zig` 1.0.2，共 194 个注册模块。不是官网默认的 common 子集，也不再限制为最初 12 种或常用语言子集。INI/TOML、Kotlin（kt/kts）和 YAML（yaml/yml）均在内置集合中；Zig 是额外补充的必选模块。第三方语法首版仅补充 Zig，内置与第三方范围以固定版本发行包和官方清单为准。

### 2.1 文件识别

所有内置语法在离线 Worker 中可用；文件识别使用显式扩展名／文件名映射，不调用 highlightAuto。上游语言别名并不全是文件扩展名，不能把所有 alias 无条件加入打开白名单。以下是必须覆盖的常用映射，其他内置源码类型也依据上游清单补齐合理映射；REPL 输出、访问日志、plaintext 等没有可靠文件名规则的模块仍打包，但不据此猜测普通 txt/log 内容。

| 扩展名或完整文件名 | highlight.js 语言 ID |
| --- | --- |
| swift | swift |
| py、pyi、pyw | python |
| js、mjs、cjs、jsx | javascript |
| ts、mts、cts、tsx | typescript |
| sh、bash、zsh；.bashrc、.bash_profile、.zshrc、.zprofile、.profile | bash |
| c、h | c |
| cpp、cc、cxx、hpp、hh、hxx | cpp |
| java | java |
| kt、kts | kotlin |
| zig | zig（额外模块） |
| go | go |
| rs | rust |
| cs、csx | csharp |
| m、mm | objectivec |
| rb、rake、gemspec、podspec；Gemfile、Rakefile、Podfile | ruby |
| php | php |
| sql | sql |
| lua | lua |
| dart | dart |
| scala、sc | scala |
| groovy、gradle | groovy |
| pl、pm | perl |
| r | r |
| json、jsonc、json5 | json |
| toml、ini、cfg；.editorconfig、.gitconfig、.npmrc | ini |
| yaml、yml | yaml |
| xml、xsd、xsl、xslt、plist、rss、atom | xml |
| css | css |
| scss | scss |
| less | less |
| graphql、gql | graphql |
| Dockerfile、Dockerfile.*、*.dockerfile | dockerfile |
| cmake；CMakeLists.txt | cmake |
| mk、mak；Makefile、GNUmakefile | makefile |
| diff、patch | diff |
| ps1、psm1、psd1 | powershell |
| proto | protobuf |

按 originalImageName 判断，缺失时使用 textURL.lastPathComponent；匹配时使用文件最后一段名称，复合文件名／固定文件名规则优先于普通扩展名，比较大小写不敏感。Gradle Kotlin DSL 的 `*.gradle.kts` 由 kts 命中 kotlin。压缩包内的文件沿用子 AppState 的原始文件名和文本内容。

`.h` 默认按 C，`.m` 默认按 Objective-C；不进行内容猜测。新增无扩展名文件必须按上表的受控文件名规则识别，不能把所有无扩展名文件当作代码。未命中的文件继续走原生只读视图。

### 2.2 打开规则与既有内容优先级

实施时同步扩展 AppState.textFilenameExtensions，加入已经核对的源码／配置扩展名；isTextFile 还需支持上述固定文件名规则，不能只在着色层认识 kt/zig/toml，却让打开流程依赖系统是否注册了相应 UTType。识别表与打开白名单从同一份小型语言映射派生，避免维护两个互相遗漏的列表。普通打开、拖放、目录列表和压缩包预览都要验证。

不改变文件关联、entitlements、Sandbox 权限。保留现有内容路由优先级：HTML/HTM/XHTML 仍作为网页，SVG 仍作为图片，Markdown 仍使用原有预览／编辑路径；即使 xml/markdown 语法已打包，也不把这些文件强制转为只读源码。plist 等二进制内容不因语法映射被强制当作文本。可编辑笔记、Markdown 代码块和扩展文档不属于此次范围。代码默认显示行号，允许按箔隐藏；不新增语言选择器、主题选择器或全局设置页。

## 3. 现有代码接入点

| 位置 | 职责与计划改动 |
| --- | --- |
| `foofoil/Views/TextEditorModeView.swift` | 保留现有只读分支，在其内部依据文件名、大小与失败状态选择代码预览或原生只读视图 |
| `foofoil/Views/ReadOnlyTextView.swift` | 保留 NSTextView 展示；代码文件回退时按需添加轻量原生行号栏，普通文本保持原样 |
| 新增 `foofoil/Views/ReadOnlyCodeView.swift` | NSViewRepresentable、专用 WKWebView 子类、Coordinator；管理页面、样式、消息与清理 |
| 新增 `foofoil/CodeLanguage.swift` | 内置语法清单、受控扩展名／文件名映射与大小判断；不持有窗口或 AppState |
| `foofoil/AppState/AppState+ContentOpen.swift` | 从语言映射扩充文本打开白名单与固定文件名识别，保留原有非文本内容优先级 |
| 新增 `foofoil/Resources/CodePreview/` | 固定页面壳、宿主脚本、样式、预打包的 Worker 高亮脚本及资源清单 |
| `foofoil/AppState/AppState.swift`、`AppState+Persistence.swift`、`SettingsStore.swift` | 保存每张箔的行号显示状态，并随 WindowConfig 恢复；不持久化行号或高亮结果 |
| `foofoil/App/AppDelegate+MenuSetup.swift`、`AppDelegate+MenuValidation.swift`、`Localizable.xcstrings` | 在视图菜单加入“显示行号”勾选项，处理活动箔、可用状态和中英文文案 |
| `foofoil/FloatingWindow.swift` | 让现有只读上下键滚动分发能够定位专用代码视图，而不再只寻找 NSTextView 所在的 NSScrollView |
| `foofoil/Extensions/DocumentFontCatalog.swift` | 复用字体名到 CSS 字族的转换；不复制字体目录实现 |
| `foofoil/Extensions/DocumentPageInjection.swift` | 复用已有的背景明暗判定等纯样式工具；代码预览自行控制其已知 DOM 的 CSS |
| `THIRD_PARTY_NOTICES.md`、两种语言的 `SupportedContent.md` | 实施时补充依赖声明、支持范围和大文件限制 |

不要直接复用 `Views/WebView.swift` 的 Coordinator。它包含网址导航、标题更新、网页保存、快照和可编辑元素跟踪；代码预览只需本地显示与少量消息，复用它会引入不需要的行为。

## 4. 依赖、资源与体积预算

使用固定版本 highlight.js 11.12.0，包含核心与全部 193 个内置语法模块，额外包含 MIT 许可的 highlightjs-zig 1.0.2。将可分发脚本及其源地址、版本、SHA-256 和许可证记录在资源清单中。Zig 使用该包的独立语法脚本，不带入它的演示页面、主题或另一份 highlight.js 核心；不自行编写 Zig 语法。依赖升级是显式维护动作，应用启动和普通 Xcode 构建均不下载、不执行 npm，也不临时生成语法文件。

使用上游公共 API：`registerLanguage`、`getLanguage`、`highlight(source, { language, ignoreIllegals: true })`。不依赖内部 emitter 或私有 token 结构。高亮结果直接用于 HTML 显示，避免 HTML 与 NSAttributedString 之间的二次转换。

2026-10-15 对官方 npm 包 `@highlightjs/cdn-assets` 11.12.0 及 `highlightjs-zig` 1.0.2 的实测（两个方案均包含核心与 GitHub 明暗 CSS）：

| 内容 | 字节数 | 约合 KiB |
| --- | ---: | ---: |
| 原 12 个模块，未压缩（对照） | 85,382 | 83.4 |
| 原 12 个模块，合并后 gzip（对照） | 26,844 | 26.2 |
| 全部 193 个内置模块，未压缩 | 1,101,247 | 1,075.4 |
| 全部内置模块＋Zig，未压缩 | 1,103,168 | 1,077.3 |
| 全部内置模块＋Zig，合并后 gzip | 313,233 | 305.9 |
| 全部内置模块＋Zig，合并后 xz | 247,860 | 242.1 |

这些数字是资源测量，不是实际 DMG 差值。ES 模块需要在资源维护时打成自包含的 Worker 脚本；最终大小会随打包方式、应用桥接代码、签名与 DMG 压缩而变化。两个上游 CSS 用作体积比较，实施可以只保留其颜色规则，移除背景、字体、粗体与斜体规则。

全量语法方案的安装包增量初步预估为 300–500 KB；第一版验收预算调整为 **不超过 512 KiB 的 DMG 增量**。原 200 KiB 预算是针对 12 个模块的假设，不再适用。该预算必须实测，超过时先查资源重复、意外带入完整 npm 包或引擎副本。全量语法是明确需求，不能为满足旧预算悄悄裁剪模块；优化后仍超出时报告实际数据，再决定是否调整预算。不得把 gzip 数值当成 DMG 承诺。

WKWebView 使用系统 WebKit，项目已有 WebKit 使用点；不随安装包分发 Chromium、Electron 或另一份 WebKit。进程可能由系统复用，不能把“一个视图”机械等同为“固定多一个进程”，也不预先承诺具体内存值。

## 5. 页面与高亮流水线

### 5.1 每个代码视图的生命周期

1. Swift 在主线程创建专用 WKWebView，使用非持久化 websiteDataStore。
2. 只加载一次随应用提供的固定 HTML 壳；页面包含一个文档容器和一个 `<pre><code>`。背景透明，页面本身负责滚动。
3. 页面就绪后，通过 `callAsyncJavaScript` 的 `arguments` 传入源码、语言、样式与 revision。源码不得拼进 HTML、脚本字符串或 URL。
4. 页面先用 `code.textContent = source` 显示普通代码，再启动 Worker 计算高亮。
5. Worker 仅接收源码、语言和 revision，调用 highlight.js 并返回 HTML 结果。页面确认 revision 后应用结果，保持滚动位置；已有文字选择时延迟替换 DOM，直到选择解除。
6. 字体、字号、间距、前景色和外观变化只更新 CSS，不重载页面、不重新高亮。只有源码或语言改变才更新内容。
7. 切换文件时递增 revision，终止旧 Worker并清除待应用结果；视图销毁时移除消息处理器、定时器与观察者，终止 Worker并回收 Blob URL。

不按 SwiftUI 每次 updateNSView 重建 WKWebView 或执行 loadHTMLString。Coordinator 保留最新请求与样式，异步完成时必须检查视图是否仍存活、revision 是否匹配。恢复历史或切换文件后，失败状态仅作用于该份内容，不能污染整个窗口以后的文件。

### 5.2 Worker 的具体装载

把 highlight.js 核心、全部 193 个内置模块、Zig 注册代码和少量任务协议预先合成一个无外部 import 的 Worker 脚本。Swift 读取固定 Bundle 资源，通过参数传给页面；页面用 Blob URL 创建 Worker。这样不依赖 file:// 页面是否允许 module Worker 或跨源资源加载，也不授予用户代码文件及其目录的读取权限。

页面和 Worker 都只执行应用自带脚本。Worker 源码不包含用户源码，用户源码只通过 postMessage 作为数据传入。Blob Worker 的 CSP 和目标 macOS WebKit 行为需在第一阶段原型中验证；不可用则回退到原生文本，不临时改成联网装载或在 UI 线程同步高亮。

全量模块预先打包，按所选语言显式高亮，不运行全量自动检测，也不在运行时下载缺失语法。资源清单记录模块 ID、别名和语法依赖；打包时处理注册顺序及嵌入语言依赖，不能只遍历文件后忽略错误。官方默认 highlight.min.js 只含 common 子集，不能直接拿它冒充全量包。

每个活动代码视图最多一个 Worker。内容高亮完成后即可终止它，保留 DOM 和源码；纯样式变化不重建 Worker。第一版不建设跨窗口任务池、页面池或永久全局缓存。

### 5.3 大小、超时与回退

| 条件 | 行为 |
| --- | --- |
| 未知语言或源码 UTF-8 超过 512 KiB | 一开始就使用原生只读视图，不创建 WKWebView |
| 固定页面超过 2 秒仍未完成源码展示 | 销毁代码预览，回退原生视图 |
| Worker 开始计算后超过 500 ms 未返回 | 页面主线程 terminate Worker；回退原生视图 |
| JS 异常、资源缺失、结果校验失败、WebContent 进程终止 | 释放预览并回退原生视图；不无限重载 |
| 视图关闭或切换内容 | 取消待处理工作，拒绝旧 revision 的消息 |

这些是初始参数，按实测调整。不能在执行同步 `hljs.highlight` 的同一线程上放 setTimeout 后宣称“可中断超时”；计时器必须位于不执行高亮的页面线程，由它终止 Worker。Swift 侧另有页面就绪/响应的 watchdog，避免完全依赖页面自己报错。

回退使用同一份 `AppState.text` 和文档样式，不重新读文件，不保存网页状态。尽量在释放前取回可用的滚动位置；进程已经终止时无法保证恢复瞬时选择，必须把这个限制列入手工验证。无新增错误弹窗或需要用户操作的降级提示。

## 6. 排版、主题与文本一致性

- `html/body/pre/code` 背景透明，容器 margin 为 0，文档四边 padding 为 24 CSS px；让留白跟随文档滚动，保持现有阅读布局。
- 采用 `white-space: pre-wrap`，长行允许换行；延续当前没有横向滚动的行为。明确 tab-size，测试缩进、空行和末尾换行。
- 使用文档当前字体与字号，不强制等宽。字号通过 CSS font-size 更新，WKWebView.pageZoom 保持 1，避免叠加字号缩放与页面缩放。
- Zig 1.0.2 的语法会产生 `hljs-numbers` 等自定义作用域，需要为其补充到标准数字颜色的 CSS 映射；用现代 Zig 样例验证内建函数、类型和数字的配色。不使用其自带整套页面主题。
- 语法主题只设置 token 前景色，重置 span 的字体、字重与斜体继承，避免着色导致排版变化。未命中 token 的字符使用文档文字颜色。
- 自选背景色时沿用现有 DocumentPageInjection 的明暗判定；否则跟随系统外观。明暗切换只修改 CSS 变量，背景仍交给箔的现有背景层绘制。
- 行高使用显式行距设置；默认值需要与现有字体实测对齐，CSS normal 与 AppKit 默认行高不能假定像素相同。
- 段距按现有只读 NSTextView 的换行段落语义落实。若有非零段距，渲染为独立的行容器并应用行后间距；不能只给整个 pre 设置 margin 后声称段距已支持。多行 span 要正确拆分并保留作用域和原始换行，行容器本身不产生额外复制字符。为行号与非零段距统一保留逻辑行结构，切换行号不重新拆分代码。
- 内容更新允许回到开头；仅样式更新应保持顶部可见的逻辑行及行内偏移，不能总是 scrollTop = 0。字号/行距变化后只保留旧像素 scrollTop 不足以维持阅读位置。

渲染前后必须验证 code 容器的 textContent 与输入源码一致，包含中文、emoji、制表符、空行、CRLF 和末尾换行。通过 HTML 解析结果时要处理 CR 被 HTML 解析器归一化的问题，例如把结果中的字面 CR 编成字符引用后再解析，并做严格一致性检查；不一致时直接回退，不能静默改写文本。


### 6.1 行号与显示开关

代码内容默认显示行号；在“视图 → 显示行号”提供勾选项，允许随时关闭。作用于当前活动箔的代码预览，不影响其他窗口，也不新增快捷键。普通文本、网页、Markdown 预览和可编辑笔记不显示此项。代码处于大文件或错误回退时，该选项仍有效。

在 AppState 保存 showCodeLineNumbers，并通过 WindowConfig 的可选同名字段持久化；未设置时按 true 处理。普通箔重启／历史恢复后保持选择；无痕箔只保留会话内状态，不新增持久化。切换代码文件沿用当前箔的选择；压缩包预览的子 AppState 使用所属窗口的该选项，避免切换条目就恢复默认。该字段只控制显示，不写回原文件、不保存行号文本。

行号按源码的逻辑行从 1 开始：CRLF 视为一次换行，软换行续行不重复编号；末尾换行后的空白逻辑行也有行号。空白行正常编号。位数按总逻辑行数计算，采用等宽数字、次要文字颜色和右对齐；9→10、99→100 等边界不得截断。行号字号跟随文档字号。

页面采用独立行号栏，行号节点放在源码容器之外，设为不可选择并对辅助功能隐藏，与源码逻辑行共享行布局；源码软换行、行距或段距改变后，两栏仍对齐。行号只负责提示位置，点击不增加选择整行等新交互。源代码的 textContent 一致性检查、DOM 文本偏移和全选范围均排除行号栏。

关闭行号时同时移除行号栏占用的宽度，源码回到原有 24 px 文档内边距。切换通过 CSS／显示状态完成，不重载页面、不重跑高亮、不清除文字选择；因可用宽度变化导致重新折行时，保留顶部逻辑行及行内偏移。字体、字号、窗口宽度和行距变化时同样检查对齐与阅读位置。

原生回退也需遵守同一开关：只给已识别的代码文件添加轻量 NSRulerView 行号栏，按可见区域绘制，不为普通文本创建行号栏。大文件的行起始位置索引在后台生成；索引未就绪时先显示可读文本，就绪后补上行号，不阻塞主线程。原生与 WebKit 路径采用相同的逻辑行计数规则，并验证回退前后显示状态、选择复制及滚动行为。

## 7. 选择、复制、快捷键和窗口行为

代码区域不可编辑，不启用 contenteditable。用 WebKit 文本选择能力，保留鼠标拖选、双击选词、全选以及 VoiceOver 阅读。网页中的查找、拼写替换、打开链接或编辑命令不应作为代码预览功能出现。

复制只输出纯文本。页面处理 copy 事件，使用 DOM 选择对应的 UTF-16 文本偏移，从保留的原始源码取片段，写入 text/plain，避免复制行号、HTML、行容器生成的空白或主题样式。全选范围限定在源码容器。验证 CRLF、跨行选择和末尾换行；若 WebKit 在目标系统上不允许所需 clipboardData 行为，再用受控的原生复制桥接补齐，不默认增加桥接。

保持 AppState 的文本内容身份；不设置 webURL，不使用网页缩放、网页保存、网页标题、截图或“在浏览器打开”菜单。现有文本字号快捷键仍更新 textFontSize。WKWebView 获得焦点后，Edit 菜单的 copy/selectAll 必须实际作用到代码内容；只在原生响应链确有缺口时增加专用子类的转发，不全局拦截键盘。

现有 FloatingWindow.scrollReadOnlyContent 的文本路径只寻找 NSTextView/NSScrollView。实施时增加专用 CodePreviewWKWebView 的滚动入口，避免上下键被窗口提前消费却无法滚动。不要把任意 WKWebView 都当成代码视图，以免影响普通网页和 EPUB。上下键、Page Up/Down、Home/End、滚轮、触控板和字号缩放都要手工验证；快捷键含义不变，不新增绑定。

文本拖选优先于窗口拖动；现有按住 ⌘ 拖窗、边缘缩放热区和滚动条交互必须保留。WKWebView 覆盖整个内容区域后，不能假定背后的 WindowDragArea 还能接收事件；应验证现有 FloatingWindow 的事件路由，必要时在专用子类中做最小衔接。

## 8. 本地页面的边界

页面不是用户提供的 HTML。固定页面壳、应用自带脚本和 highlight.js 生成的 span 标记构成展示层；源码始终以数据进入，不执行其中的 script、事件属性、URL 或 Markdown/HTML。

- 使用固定 CSP，默认拒绝资源与网络请求；只允许固定启动脚本（nonce/hash）、所需内联样式和 Blob Worker。具体策略随原型实测定稿，不使用 unsafe-eval。
- 不从 CDN 加载脚本、主题或字体，不使用 importScripts 下载资源，不给用户文件目录设置 allowingReadAccessTo。
- NavigationDelegate 只允许初始化固定壳需要的主 frame 导航；此后取消所有页面导航、新窗口和下载，不调用 NSWorkspace 打开源码中的网址。
- 明确一个内容世界承载受信页面脚本与宿主调用，避免启动脚本与 callAsyncJavaScript 使用不同 WKContentWorld 导致函数不可见。
- 脚本消息仅包含 ready/rendered/failed 及 revision 等必要字段；只接受当前 WebView 主 frame 的有效消息。不开放文件读取、任意 URL、任意命令或任意脚本执行接口。
- 只有固定版本 highlight.js 返回的 HTML 可以进入高亮结果容器，原始 source 不能进入 innerHTML。不引入能输出用户 HTML 的插件。用 `</script>`、事件属性和标签文本验证没有脚本执行或网络访问。
- 不改变现有 entitlements、Sandbox 或文件权限，不写 Cookie、localStorage、IndexedDB，不持久化源码副本。清理消息处理器，防止 WKUserContentController 与 Coordinator 形成长期引用。

## 9. 验证与验收

### 自动验证

1. 扩展名／固定文件名识别、打开白名单、大小边界与资源清单完整性；特别覆盖 kt/kts、zig、toml、yaml/yml、CMakeLists.txt、Dockerfile 与无扩展名文件。
2. 将固定版本资源清单与实际打包、Worker 注册的语言 ID 做集合相等校验：全部 193 个内置模块加 Zig，共 194 个，不能只验证数量。使用 debugMode 暴露注册／高亮错误，生产使用默认安全模式；每个模块使用其上游代表样例做实际 WKWebView/Worker 冒烟测试，重点校验 Kotlin、Zig、TOML、YAML 的 token 与主题作用域，以及 JSX/TSX、Dockerfile 等嵌入语言。plaintext 等无 token 语法只要求成功处理和文本一致。不能只模拟 JS 返回值。
3. 渲染前后源码一致、纯文本复制一致，覆盖中文、emoji、反引号、HTML 标签、CRLF、空行、末尾换行和多行注释。
4. revision 切换、资源缺失、Worker 超时、页面无响应和进程终止可回退；旧结果不能写回新文件。
5. 主题/字体/字号/间距更新不重新加载、不重新高亮，不篡改源码；选择存在时 DOM 替换延迟生效。
6. 行号默认开启、切换立即生效、只作用于当前箔、历史恢复与无痕行为正确；覆盖 CRLF、空行、末尾换行、软换行续行不重复编号以及 9/10、99/100 位数边界。检查显示／隐藏行号前后的源码一致、选择与复制不含行号、滚动锚点和原生回退行号。
7. 现有文档样式、文本缩放与只读滚动相关测试保持通过。

### 手工检查

亮色、暗色、自选背景、透明窗口；不同字体与字号；默认与非零行距/段距；长行和跨行选择；行号显示／隐藏、两栏对齐、菜单勾选、跨窗口与恢复行为；⌘A/⌘C 与菜单命令；上下键和翻页；滚轮、滚动条、缩放热区和 ⌘ 拖窗；多窗口、压缩包预览、历史恢复、无痕窗口。确认无网页菜单和源码导致的外部访问。

### 包体与运行成本

用同一 main 基准、相同 Release 架构、签名、内嵌模块和 package-dmg 参数，分别构建基线与候选。记录 .app 文件大小、资源总量和最终 DMG 字节差；确认候选不包含 Tree-sitter 解析器、完整 node_modules、源码映射或浏览器引擎。不要用 Debug .dylib 或 gzip 数值替代发行包测量。

测量冷启动/热启动的首份可读文本和首次着色耗时，以及 1、5、10 个代码窗口的宿主与 WebContent/Worker 进程树占用；分别使用小文件和接近 512 KiB 的文件。记录设备与系统版本。关闭窗口后观察占用是否趋于稳定；WebKit 可能保留进程，不能仅凭进程尚存判定泄漏。

首版必须满足全部内置语法与 Zig 完整打包、DMG 增量不超过 512 KiB、普通测试文件在 Worker 时限内完成、超时不拖死窗口，以及上述交互无回归。内存与冷启动没有实测数据前，不宣称比原生方案更省。若其多窗口成本不可接受，应暂停合入，另行评估 JavaScriptCore＋NSTextView，而不是在同一次实现中维护两套高亮后端。

## 10. 实施顺序

1. 从 main 创建独立实现分支。先用一个离线页面和一个语言验证 Blob Worker、CSP、源码往返、复制及浮窗事件；此阶段就打一次 Release 包，确认体积方向。
2. 补齐全部 193 个内置语法与 Zig，联通文件名识别和文本打开白名单，再加入 revision、超时与原生回退，除每张箔的行号显示状态外，不引入其他设置或持久化字段。
3. 接入默认显示的行号及隐藏开关、状态恢复和原生回退行号；同时接入现有字体、颜色、行距/段距、文本缩放、滚动和选择保留。
4. 完成自动与手工验证、包体和多窗口测量，更新依赖声明及两种语言的支持内容说明。若快捷键行为确有调整，再同步两份快捷键说明。
5. 实施完成后运行 ./run 供直接查看。达到验收前不合入 main，不删除原生实验分支。

## 11. 资源范围核对

本次文档修订已从固定版本 npm 发行包枚举 193 个内置语言模块，使用其 ES 发行文件及独立 Zig 脚本完成 194 个模块的 Node 注册检查，并验证 Kotlin、Zig、INI/TOML、YAML 的简单样例可产生 token。该检查只验证依赖层可用性，不等同于尚未实施的 WKWebView、打开路由、主题或完整语言质量验收。

内置模块集合（按发行包文件名排序；不含额外 Zig）：

```text
1c abnf accesslog actionscript ada angelscript apache applescript arcade
arduino armasm asciidoc aspectj autohotkey autoit avrasm awk axapta
bash basic bnf brainfuck c cal capnproto ceylon clean
clojure-repl clojure cmake coffeescript coq cos cpp crmsh crystal
csharp csp css d dart delphi diff django dns
dockerfile dos dsconfig dts dust ebnf elixir elm erb
erlang-repl erlang excel fix flix fortran freedesktop fsharp gams
gauss gcode gherkin glsl gml go golo gradle graphql
groovy haml handlebars haskell haxe hsp http hy inform7
ini irpf90 isbl java javascript jboss-cli json julia-repl julia
kotlin lasso latex ldif leaf less lisp livecodeserver livescript
llvm lsl lua makefile markdown mathematica matlab maxima mel
mercury mipsasm mizar mojolicious monkey moonscript n1ql nestedtext nginx
nim nix node-repl nsis objectivec ocaml openscad oxygene parser3
perl pf pgsql php-template php plaintext pony powershell processing
profile prolog properties protobuf puppet purebasic python-repl python q
qml r reasonml rib roboconf routeros rsl ruby ruleslanguage
rust sas scala scheme scilab scss shell smali smalltalk
sml sqf sql stan stata step21 stylus subunit swift
taggerscript tap tcl thrift tp twig typescript vala vbnet
vbscript-html vbscript verilog vhdl vim wasm wren x86asm xl
xml xquery yaml zephir
```

## 参考

- [highlight.js 官方定制构建](https://highlightjs.org/download)
- [固定版本全部内置语法与别名](https://github.com/highlightjs/highlight.js/blob/11.12.0/SUPPORTED_LANGUAGES.md)
- [Zig 语法模块](https://github.com/fwx5618177/highlightjs-zig)
- [Zig 1.0.2 发行包元数据](https://registry.npmjs.org/highlightjs-zig/1.0.2)
- [highlight.js 公共 API](https://highlightjs.readthedocs.io/en/latest/api.html)
- [官方 CDN 资源包 11.12.0 元数据](https://registry.npmjs.org/@highlightjs/cdn-assets/11.12.0)
- [Apple WKWebView](https://developer.apple.com/documentation/webkit/wkwebview)
- [Apple callAsyncJavaScript](https://developer.apple.com/documentation/webkit/wkwebview/callasyncjavascript(_:arguments:in:contentworld:completionhandler:))
- [Apple WKScriptMessageHandler](https://developer.apple.com/documentation/webkit/wkscriptmessagehandler)
