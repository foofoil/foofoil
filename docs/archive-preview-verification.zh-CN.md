# 压缩包预览实施与验证记录

日期：2026-10-15。本文记录实际交付和未完成项，不能将系统库支持格式的名称理解为完整兼容保证。

## 后端选择

使用系统 `/usr/lib/libarchive.2.dylib`，只启用 ZIP、TAR、7z、RAR、RAR5 读取器以及 GZip/BZip2/XZ 过滤器。没有启用可能访问外部文件的 mtree 读取器，也不启用依赖外部解压程序的过滤器。产品不调用 `tar`、`unzip`、`7z` 或 Homebrew 程序。

本机为 Apple Silicon、macOS 27.0.1（26A434），系统库报告 `libarchive 3.7.4`。SDK 提供 `libarchive.2.tbd` 及本次使用的符号，没有提供头文件；`ArchiveBridge.h` 只声明用到的稳定 C ABI。部署目标保持工程原有的 macOS 26.5。**没有在 macOS 26.5 实机上复测，因此不能将本机结果视为最低系统验证。**

没有将第三方库实现编入产品。许可证说明见 `THIRD_PARTY_NOTICES.md`。可选上游测试样本固定为 [libarchive v3.7.4](https://github.com/libarchive/libarchive/tree/v3.7.4/libarchive/test)，只下载到指定的临时验证目录，并保留其 COPYING。

## 实测矩阵

“成功”表示本机样本完成目录枚举及完整流式提取；目录中的链接按策略跳过。失败样本没有进入成功提交路径。

| 格式／组合 | 枚举 | 提取 | 依据／限制 |
| --- | --- | --- | --- |
| ZIP Store、Deflate、ZIP64 entry | 成功 | 成功 | 自建 UTF-8 中文名、空目录样本；ZIP64 entry 强制使用 ZIP64 扩展 |
| ZIP BZip2、LZMA | 成功 | 成功 | Python 标准库生成的样本 |
| ZIP 传统加密 | 成功 | 成功 | 自建及上游样本；目录不加密 |
| ZIP AES-128、AES-256 | 成功 | 成功 | 上游及自有固定盐样本；正确、错误、空密码均有自动测试 |
| ZIP AES-192、强加密中央目录 | 未测 | 未测 | 不声明支持 |
| ZIP 分卷 | 不支持 | 不支持 | 主 ZIP 的 EOCD 分盘字段及 `.zNN` 入口明确拒绝，不拼接分盘 ZIP |
| TAR/PAX、TGZ、TAR.BZ2、TAR.XZ | 成功 | 成功 | 中文名、空目录、符号链接样本；符号链接跳过 |
| 独立 GZ/BZ2/XZ | 成功 | 成功 | Raw 单文件结果；缺省名称为去掉压缩扩展名的文件名 |
| 7z LZMA1、LZMA2、BZip2、PPMd | 成功 | 成功 | 上游样本及系统 bsdtar 自建样本；不承诺全部过滤器、字典尺寸或固实组合 |
| 7z 内容加密、加密文件名 | 内容加密可列；文件名加密不可列 | 不支持 | 系统库实测不能解密，明确报告后端限制 |
| 未加密 RAR、RAR5 | 成功 | 成功 | 上游 Store/Compressed/多文件/ARM/Blake2 等正常样本 |
| RAR5 固实、多文件固实 | 成功 | 成功 | 上游 solid、multiple_files_solid 样本 |
| RAR 内容加密、加密文件名 | 部分可列 | 不支持 | 系统库无法完成解密，不将错误归结为必然是密码错误 |
| 7z 分段流 | 成功 | 成功 | 将有效 7z 分为三段，通过多文件读取 API；缺末段失败 |
| RAR 分卷 | 成功 | 成功 | 四卷上游样本；缺末卷或仅首卷失败 |
| RAR5 分卷 | 成功 | 成功 | 八卷上游样本；缺末卷或仅首卷失败 |
| RAR5 固实＋分卷 | 成功 | 成功 | 四卷上游样本；缺末卷或仅首卷失败 |
| 加密＋分卷、加密＋固实＋分卷 | 未支持 | 未支持 | 不从未加密卷组推断支持 |
| 重名文件、大小写冲突 | 成功 | 整目录拒绝冲突；单项可提取 | 物理序号保持独立身份，重复项显示序号徽标 |
| 异常路径、损坏、缺卷 | 明确失败或提取失败 | 不提交输出 | 不能保证检测出所有可能的损坏形式 |

文件名优先采用系统库提供的 UTF-8 名称，无法得到有效 UTF-8 时拒绝建立索引。UTF-8 中文名已测；历史编码和 Unicode extra field 的完整样本矩阵尚未覆盖，不声明对任意 GBK/CP437 归档的自动识别。

## 实现范围

- `ArchiveReader`：有界索引、安全路径、稳定序号、目录与普通文件类型分离、流式读取与原包变化检测。
- `ArchiveWorkQueue`：同一会话的索引、预览、导出串行执行；取消任务轮到执行时立即退出，避免快速点击累积并行固实解压。
- `ArchiveSession`：原包及卷组授权、选择、密码、任务代次、只读派生阅读器和缓存持有关系。原包不进入内容缓存。
- `ArchiveExport`：在系统替换目录提取，全部成功且未取消后才提交；不合并既有目录、不允许覆盖原包或其硬链接。
- `AppState`：原包拥有历史 UUID、来源指纹和固定图标；派生阅读器为独立无痕上下文，不写历史、运行时快照或缩略图。SQLite schema 21 保存原包与卷组引用及书签。
- 现有正文阅读器复用图片、PDF、文本、Markdown、CSV、网页、Quick Look、自包含文档及音视频；内容目录被隐藏。正文的 EPUB、PDF、PPT 与媒体快捷键分别转发到派生阅读器；文件树面板中的方向键用于树操作。
- 原包与每个卷的路径、文件大小、修改时间、文件标识在每次提取前后核对。变化时索引失效，要求重载。没有持续监控原包；已有预览可持续显示至下次操作。
- 正常文件入口、拖放、剪贴板、分享和历史恢复均接入。Finder 的原文件继续引用原路径。其他应用只提供临时导出、以及现有无痕分享暂存流程时，仍沿用分享入口的源文件接收机制；这属于来源交接，不能声称所有分享来源绝无复制。

## 安全与资源边界

最多 100,000 个树节点、128 层路径、32 MiB 路径元数据，每个来源卷最大 8 GiB。预览提取与导出每次累计输出最大 20 GiB，不再额外按文本/其它类型设置 16/512 MiB 门槛。顺序提取工作量按已扫描条目的声明大小保守计算，预算为输出预算四倍，最低 512 MiB、最高 20 GiB。

扫描、预览提取、导出提取分别以 120、300、300 秒为限；检查发生在原生读取调用之间，不能承诺中断正在执行的单次 C 调用。系统库不能设置独立字典内存硬上限，因此输出限额不等于解码器内存限额。无无界中间 TAR 缓存，后部条目以重复顺序扫描读取。

输出使用 64 KiB 缓冲。路径拒绝绝对路径、驱动器路径、父级逃逸和超深路径；不写符号链接、硬链接、特殊节点或原始权限。目录导出任一条目失败就回收本次暂存区，不提交部分目录。成功时报告跳过数量。重名冲突的决策为中止整次导出并允许用户逐项指定新名称。

密码只在当前会话和必要的在途读取任务内持有，不进入配置、日志和历史。不同密码的条目可分别选择、解锁、导出；同一次目录导出只使用当前密码，任一失败就中止。关闭清理缓存；原生运行时关闭尚未结束或释放失败需要重试时，保留缓存租约直至实际关闭完成。

## 自动验证与复现

应用测试使用 Swift Testing 的 `ArchiveTests`，包括路径逃逸、深度、隐式与空目录、重复文件、大小写冲突、原始字节、资源超限、源变化、已有目标不被失败覆盖、禁止覆盖原包、SQLite 原包来源恢复、快速切换、关闭后来源保留、缓存租约、AES-128/256 正确／错误／空密码。

相关回归命令（仓库根目录）：

```sh
xcodebuild test -project foofoil.xcodeproj -scheme foofoil \
  -destination 'platform=macOS' -derivedDataPath build \
  -only-testing:foofoilTests/ArchiveTests \
  -only-testing:foofoilTests/ChapterNavigationTests \
  -only-testing:foofoilTests/ContentSavingTests \
  -only-testing:foofoilTests/NavigatorSearchTests \
  -only-testing:foofoilTests/FileOpenFeedbackTests \
  -only-testing:foofoilTests/ShareContentTests \
  -only-testing:foofoilTests/IncognitoFoilTests \
  -only-testing:foofoilTests/ContentCacheTests \
  -only-testing:foofoilTests/ExtensionLifecycleTests
```

后端样本脚本仅用于开发，不是产品依赖：

```sh
python3 scripts/verify-archive-backend.py /tmp/foofoil-archive-fixtures --upstream
xcrun swiftc -parse-as-library \
  -import-objc-header foofoil/Archive/ArchiveBridge.h \
  foofoil/Archive/ArchiveReader.swift scripts/archive-backend-harness.swift \
  -larchive.2 -o /tmp/foofoil-archive-harness
/usr/bin/time -l /tmp/foofoil-archive-harness /tmp/foofoil-archive-fixtures
xcrun swiftc -parse-as-library \
  -import-objc-header foofoil/Archive/ArchiveBridge.h \
  foofoil/Archive/ArchiveReader.swift scripts/archive-volume-harness.swift \
  -larchive.2 -o /tmp/foofoil-archive-volumes
/tmp/foofoil-archive-volumes /tmp/foofoil-archive-fixtures
```

20,000 个文件样本生成 20,201 个节点；索引加完整写出约 6 秒（随磁盘负载变化）。多格式样本批次的独立验证进程峰值 RSS 约 36 MB，peak memory footprint 约 23 MB；这不是整个 GUI 进程的内存峰值，也不是安装体积。

## 尚未完成与替代方案

以下项目仍未达到原计划的全部验收条件，不能勾选为完整完成：

1. **加密 7z/RAR、加密文件名、ZIP 分卷和加密分卷组合。** 系统后端实测缺少能力。仅重新内置同版本 libarchive 不能解决已知的解码能力缺口；后续需要评估支持这些组合的专项后端或经过裁剪的 7-Zip 兼容解码实现，单独审查许可证、取消机制、字典内存控制和分发体积。本次没有引入未经验证的依赖，也没有测得替代后端的实际 App/DMG 增量。
2. **最低支持系统、多种历史文件名编码、全部固实/算法组合、字典内存硬限制。** 本机测试不能替代这些验收。
3. **真实磁盘不足、文件授权失效、普通 EPUB 的完整人工场景、多显示器/多窗口、双外观和 GUI 预览缓存压力峰值。** 自动回归和本次混合样本检查不等于全部人工验收。
4. **Developer ID 公证。** 本次执行本地 Release/UDZO 打包与签名结构检查；不将未提交的 Apple 公证流程写为通过。

## 人工检查与修复记录

在实际 Debug 应用中完成以下检查，使用本地自建混合 ZIP：

- 初始只显示“请选择要打开的文件”；空目录为目录节点，可选择且可保存。
- 通过原生 NSSavePanel 保存空目录；保存根目录默认名为压缩包去扩展名的名称。
- 根目录导出 10 个文件、17,917,920 字节，逐项与 ZIP 中原始字节比对一致，空目录保留。17 MiB 文本超过预览限额但仍可正常导出。
- 文本、EPUB、PDF、CSV、Markdown、图片、音频连续切换，压缩包树保持原有展开状态；只读文本的原生文本控件不提供可编辑属性。
- 包内 EPUB 只显示正文，压缩包树保持显示；左右键与“前往”菜单均能切换两个章节，首章“上一章”禁用。
- 包内 PDF 可显示并接收翻页命令；全屏和普通窗口之间切换后继续显示。
- CUE 显示另存所在目录的说明；超限文本保留另存入口；切换根节点和文件后包内路径正确更新。

人工检查发现并修复：借用缓存 URL 引发的 imageURL 递归赋值（补图片回归测试）；普通内容替换原包时沿用 UUID（补身份回归测试）；可选择 SwiftUI Text 复用导致旧路径的无障碍值残留（按条目重新建立路径视图）；目录导出 Unicode 大小写折叠冲突（保守拒绝，暂存文件也禁止覆盖）；密码重试时旧 sheet 的 dismiss 回调不能清除新一次重试。

RAR4/RAR5 卷组在索引前验证末卷 ENDARC 记录、CRC 和后续卷标志，允许合法零字节填充。上游完整卷组继续通过；缺末卷和仅首卷均失败。自建 RAR5 Store 样本验证：已有文件全部完整、但 ENDARC 仍声明后续卷时，也必须拒绝建立可导出的索引。

后端另验证保留字符 `#` 的目录不会与隐式目录 ID 冲突；物理条目和隐式目录使用互不重叠的数值命名空间。

发布验证还发现原打包脚本没有单独为两个分享 appex 建立资源封印。`package-dmg` 现先用工程既有的分享扩展 entitlements 签名两个 appex，再签内容能力和宿主；没有修改 entitlement 配置。使用本地 ad-hoc 签名，`codesign --verify --deep --strict` 通过。尚未使用 Developer ID 提交 Apple 公证。

## 最终构建与体积

相关回归共 **71 项通过，0 失败，0 跳过**。包括新增密码会话的缺省密码、错误密码、取消和正确密码重试。最终后端样本还验证 Unicode 大小写折叠冲突中止、保留字符目录 ID 无冲突。新增归档源文件没有编译警告；工程既有的非隔离/主 actor 警告仍存在，没有为本功能静默压制。

基线为本次工作前的 HEAD（`7e4b65c56736d4bc67a13fecbc31c007a56234cf`），取相同兄弟能力模块；基线和当前版本均采用相同的分享扩展签名修正、本地 ad-hoc 签名、相同 Release/UDZO 打包流程。签名分支均移除工程测试用 XPCServices。App 字节为包内实际文件大小之和（排除符号链接重复计数），并非磁盘分配块或运行缓存。

| 产物 | 基线字节 | 当前字节 | 增量字节 |
| --- | ---: | ---: | ---: |
| Release App | 31,006,251 | 31,505,712 | 499,461 |
| UDZO DMG | 10,326,683 | 10,460,752 | 134,069 |

系统 libarchive 的动态链接已由 `otool -L` 验证；没有 Homebrew 或第三方可执行文件运行依赖。`codesign --verify --deep --strict` 通过的是本地 ad-hoc 签名，不能表述为 Developer ID 或 Apple 公证通过。精简内置替代后端没有实际构建/体积数据。

已执行 `./run`，构建并启动 Debug 应用，供直接检查。预览缓存的 GUI 压力峰值仍未实测；上文独立后端进程的 RSS、导出字节和安装体积分别记录，不能相互替代。


## 包内外呈现统一（2026-10-15 后续修正）

移除归档专用正文阅读器，普通文件与包内文件共用 `FoilContentView`，包括默认文档主题、正文背景、留白、边框与音视频组件。压缩包会话只管理目录、所选文件的临时提取和导出；正文命令、样式面板、播放控制、缩放与内容截图跟随当前条目，窗口及历史仍归原包。不再常驻显示只读/关联资源说明。

所有常规文件使用同一个 `openFile` 入口，不按类型另设预览白名单。修正 JS 等源码同时符合 executable 类型而被提前拒绝的问题；包内外一起修复。ISO 与嵌套压缩包不再被直接拦截，嵌套目录可通过导航来源切换，Markdown/EPUB 仍保留自身内容导航。CUE 或网页/Markdown 引用的外部文件仍不会自动提取。

本轮 77 项相关测试全部通过（动态参数展开为 80 次），覆盖实际 JS 文本、Markdown/CSV 与普通打开的主题/文本对照、边框和全屏同步、正文缩放、嵌套压缩包目录及状态订阅、历史来源保留，以及原有导出、导航、截图、隐私、取色面板和背景测试。仍不宣称已穷尽每种编码、每种媒体容器及所有编解码器；归档后端格式限制不受此次呈现统一改变。


本轮原生窗口检查使用自建 `Unified-Preview.zip`：确认 Markdown 默认主题及标题大纲、JS 中文源码、WAV 输出设备/播放进度/暂停、音频有边框与无边框切换、MP4 播放条及音轨字幕入口；继续进入嵌套 ZIP 中的 EPUB，正文从 Chapter One 正常切换至 Chapter Two。成功正文没有常驻只读说明，压缩包目录仍可从导航来源切回。执行 `./run` 构建并启动当前 Debug 应用。


## 嵌套包惰性树（后续修正，取代导航来源切换方案）

压缩包箔的侧栏只保留一个归档目录贡献，不展示 EPUB 目录或 Markdown 大纲；EPUB 的章节命令仍走当前阅读器。内层压缩包以文件名、归档图标和展开箭头留在原树中，普通选中只显示信息，不读取其目录。首次展开才提取所选包并扫描该层目录，不递归扫描更深的包；加载状态和错误显示在对应行。折叠节点或其祖先会取消其下尚未完成的加载，关闭或重新加载外层包会释放整棵缓存。已读目录在当前会话中复用，折叠不会停止已打开文件的阅读或播放；搜索仅覆盖已读目录。

嵌套节点按来源条目 ID 组合定位，同名包、同名文件及多层来源不会混淆。内层密码仅交给对应来源，提示会显示包名；单个内层包损坏不破坏外层目录。预览和导出仍使用所选文件的实际包来源；导出目标保护同时覆盖外层原包和缓存来源，读取缓存文件前重新校验外层原包签名（清除 Foundation URL 的属性缓存，确保变化检查实际读取文件状态）。

整棵已读树共享 100,000 节点、128 层总深度和 32 MiB 路径元数据预算，内层包文件缓存合计不超过 20 GiB；每次提取与系统库的既有限制仍适用。固实格式定位内层包仍可能顺序读取此前数据，不承诺随机访问。

自动回归覆盖：选中不提取、首次展开、逐层读取、目录缓存复用、祖先折叠取消与重新加载、同名来源隔离、内层损坏隔离、内层密码错误/正确重试、外层文件变化使缓存失效、导出保护，以及包内 Markdown 大纲不会进入侧栏。


本轮相关套件 79 项测试通过（动态参数展开为 82 次），随后归档套件 24 项复测通过，包含新增总深度边界及跨层深度超限时丢弃目录的检查。实际窗口验证：Unified-Preview.zip 中选中 nested.zip 不打开其目录，点展开箭头后内容直接挂在原节点下；折叠/再展开恢复已读子树，当前 EPUB 正文不变；包内 EPUB 从 Chapter One 翻至 Chapter Two，侧栏始终显示压缩包树，没有导航来源切换菜单或书籍目录。已执行 `./run` 构建并启动当前应用。

## 容器格式、普通 ISO 与双模式历史（2026-10-16）

- 新增默认包浏览：APK、JAR/WAR/EAR、CBZ/CBR/CB7/CBT、KRA。继续使用系统 libarchive，不增加依赖，不执行安装包，不反编译编译资源。
- 启用系统 ISO 9660 读取器，无需挂载；常见 Joliet/Rock Ridge 扩展由读取器处理。纯 UDF 与 DMG 不在此次支持范围，已有大小和输出预算继续适用。
- `.iso` 优先通过现有音频 provider 的内容探测识别 SACD，宿主不重复实现 SACD 格式解析。外部及包内 SACD 均保留音频呈现；普通内嵌 ISO 仅在展开时读取目录，选择时可提取并缓存以区分 SACD。
- Office ZIP 容器（含宏、模板及 OpenDocument 格式）与 EPUB 保留原预览。“文件 → 打开包内容”和正文上下文菜单在新箔片中打开原包。旧版 DOC/XLS/PPT 无此入口。
- 历史按来源及是否包浏览分别去重；同一文档普通预览和包浏览各自保留记录，包记录恢复为未选择状态的包树，文档记录仍恢复原阅读器。保留文件名和独立图标，不以缓存文件名作为标题。
- 从包内文档另开时，普通箔复制到统一管理的持久缓存，并将来源纳入缓存引用和活动路径保护；无痕箔只共享临时租约。创建会话时即传入租约，覆盖异步扫描生命周期。原文件移动时，菜单优先使用当前会话解析后的实际资源。

自动验证：

- 72 项回归通过（ArchiveContainerTests、ArchiveTests、HistorySearchTests、ShareContentTests、FileOpenFeedbackTests、ContentCacheTests、NavigatorSearchTests、ChapterNavigationTests）；对应日志 `/tmp/foofoil-containers-final-tests.log`。
- 随后补充原文件路径失效回归，7 项容器专项全部通过（参数化测试另有动态用例），日志 `/tmp/foofoil-containers-menu-tests.log`。
- 覆盖改后缀的 ZIP 容器实际正文预览、自建 ISO 9660 读取与原字节导出、嵌套 ISO、SACD sniff 分流、Office/EPUB 新建包会话与恢复、两种历史反复打开互不覆盖、包内文档的无痕租约及普通持久缓存。
- `./run` 成功构建并启动，日志 `/tmp/foofoil-containers-run.log`。此次未重新执行 Release 打包与公证。

原生界面验证：

- 自建 DOCX 默认显示 Quick Look 正文；“打开包内容”新建包箔，根节点保留 `Package-Preview.docx`，`word/document.xml` 使用共用代码高亮预览。
- 历史菜单同时显示两条 Word 记录，选择普通预览记录仍恢复 Word 正文。
- 自建 EPUB 默认显示章节正文，“打开包内容”另开根节点为 `Package-Book.epub` 的包树，含 mimetype、META-INF、OEBPS。
- 系统生成的 ISO 9660/Joliet 镜像直接显示 `Ordinary.iso` 目录，内部 `script.js` 正常显示代码，无挂载操作。
