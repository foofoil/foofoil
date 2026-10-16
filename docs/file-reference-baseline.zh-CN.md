# 文件引用、正文归属与历史基线

日期：2026-10-16。对应 `history-file-handling-implementation-plan.md` 的 H01—H06。以下“原行为”来自修改前源码；“实施后”来自当前源码及自动化测试，不代表全部真实应用交互已验收。

## 入口盘点与最终归属

| 来源／类型 | 原行为／读取与恢复路径 | 实施后／所有权与验证 |
| --- | --- | --- |
| 本地图片、SVG | `applyImage` 和 `imageURL.didSet` 调 `cacheImage`；PNG/BMP/TIFF 可能转 HEIC；恢复可猜测缓存文件名 | 两处隐式复制均移除；直接读原 URL，用 `videoBookmark` 复用文件书签；不再猜测或回退旧缓存；`FoofoilTests.testImageCaching` 验证原文件不被历史删除 |
| 文本、Markdown、CSV、代码 | `openTextFile` 复制为 `cached_text_<id>`，配置还携带文本；恢复失败回退配置正文 | 直接读原文件、记录书签；显式重开重读正文，同路径替换可见；读取失败反馈，不以旧正文恢复；`testOpenedTextFileReferencesOriginal` |
| PDF | `NSImage` 可承载 PDF；与图片通道一起可能复制 | 直接引用并复用文件访问生命周期；`HistoryWindowFrameTests`、`ContentBackgroundTests`、PDF 既有测试 |
| 本地 HTML、XHTML、webarchive | `openWeb` 复制为 `cached_web_<id>`；WebKit 读取本地缓存 | 直接引用，书签恢复；`WebView.loadFileURL(...allowingReadAccessTo: url)` 的受限范围保持原样；`testOpenedLocalWebFileReferencesOriginal` |
| Quick Look、Office | `applyExternalMedia(...usesQuickLook: true)` 原文件与书签；异步缩略图探测 | 保持原文件，不把预览图当正文；共用新的 `FileReference` 定位结果；`QuickLookTests`、`PPTXDocumentTests` |
| 本地音视频 | 原 URL、书签、同目录封面授权；部分分片 MP4 有派生播放副本 | 保持原引用；播放副本仍属派生数据；历史查询不再按 `fileExists` 直接删除；`VideoHistoryThumbnailTests`、媒体与列表测试 |
| Hi-Fi、视频模块 | 宿主请求携带原 URL／书签；模块读取原文件；宿主保存会话状态引用 | 不复制正文、不引入模块 ID 判断；检查 `HiFiExtensionRuntime.RuntimeResourceAccess`、`VideoExtensionRuntime`；宿主模块恢复与播放既有测试 |
| EPUB | 宿主引用原 EPUB，模块 `RuntimeResourceAccess` 持有书签访问；运行时解包目录有实例锁 | 保留原容器；状态快照和临时章节解包不作正文副本清理；检查 `EBookRuntimeController`；`ExtensionDocument*Tests` |
| 压缩包、多卷、嵌套包 | `ArchiveSource.volumes` 保存原卷路径／书签；`ArchiveSession` 临时提取、按会话释放 | 保持原卷；缺失检查使用卷定位结果；包内“打开包内容”新窗口共享提取租约，不再生成 `cached_package_` 正文或独立历史；`ArchiveTests`、`ArchiveContainerTests` |
| 图片／音视频文件列表 | `FileListItem.path/bookmark` 存原来源，但图片展示还复制缓存 | 图片也直接引用；当前项和可切换项均参与活动使用统计；部分条目确认缺失才裁剪，全部缺失才清除；`FileReferenceLifecycleTests.partialListsKeepAvailableItemsAndHonorDisabledCleanup` |
| Finder 服务、文件关联、拖放、快速打开 | 经 `openFile`／`openFileGroup` 分流 | 复用上述统一入口；Finder 剪贴板文件优先于图片数据；现有 `FinderServiceTests`、`FileOpenFeedbackTests`、拖放／列表测试 |
| 分享真实文件 | `SharedItemLoader` 优先 `public.file-url`，交宿主打开原文件 | 保持原引用；不把 Finder 原文件当临时导出；`ShareContentTests` |
| 分享临时导出 | `loadFileRepresentation` 先暂存，`SharedFileImport` 再保存到 `Shared Items/<UUID>/<name>` | 该路径认定为应用托管正文，历史／窗口／任务共同保留；无痕导出使用 `Session Shared Items`，释放后清理；原始导出文件名保留 |
| 只有网址／复制图片地址 | 走网址打开，不归档网络正文 | 保持网址语义；不新增下载；`ClipboardContentDetectionTests` |
| 剪贴板图片数据 | `NSImage` 重编码 PNG 并缓存，`imageSource=.clipboard` | 优先保留实际 PNG/GIF/JPEG/TIFF 表示，无原始表示时无损 PNG；单独的 `managed_body_` 或 `session_body_` 正文；来源标记；`FileReferenceLifecycleTests.clipboardImageRetainsRepresentationAndFileReferenceWins` |
| 剪贴板文本／Markdown／HTML | 文本主要依赖配置正文；HTML 写 `cached_web_` | 自动保存正文，文本编辑写回同一文件，HTML 只保存片段；以 `clipboard:<id>` 标记来源；历史卡片、搜索行与信息面板可识别；生命周期专项测试 |
| GUI 便笺 | 文本存历史配置，GUI 可编辑 | 文本防抖后托管落盘，空内容编辑也落盘；不新增另存为确认；仍可编辑且保留便笺窗口尺寸 |
| 截图 | 页面截图／摄像头截图用于预览；新建截图箔可能编码 HEIC | 可重建页面截图仍是派生缓存；独立截图箔使用托管 PNG；无痕内容只会话持有 |
| 摄像头 | 配置保存设备／窗口状态，画面来自设备 | 不进行文件缺失清理，不将画面缩略图认作外部正文 |
| 内置帮助 | 稳定 `foofoil:` 来源标识，恢复时由资源与当前快捷键重建 | 继续重建，不保存成用户原文件，不参与失效文件清理 |
| Apple Music 等非文件媒体 | 由资料库引用与模块会话提供内容 | 不按本地路径检查；封面仍是派生资源 |

`WindowConfig.id` 在同条历史的恢复与保存之间保持一致；新内容旋转身份。书签继续复用 `videoBookmark` 字段（历史名称保留，不新增同义字段），列表及多卷继续使用各自书签。

## 定位、授权与异步生命周期

- `FileReference.resolve` 先解书签，再探测目标；结果区分可用、确认丢失、需授权、卷离线、暂时失败。过期但可解的书签刷新；损坏书签导致的不确定结果保留。
- 不将 `fileExists == false` 当作删除依据。只对可读取本地目录下的明确 ENOENT 判丢失；未挂载外置卷、网络卷、权限及未知错误保留。
- 窗口只释放自己成功取得的 security scope；后台定位的 scope 在同一次探测内归还。模块和压缩包继续由其会话持有访问。
- 启动及历史刷新通过独立串行队列按主键分页，每批 32 条检查；提交前比对完整快照，重新读取清理开关。打开／恢复前再次定位。无常驻文件监听。
- 仓库删除先排空待写入列表、取消索引；SQLite 删除正文索引分块，清理窗口恢复配置及缩略图。进程内删除 ID 拦截后续 `upsert`，退出快照也排除这些窗口，防止复活。
- 正文、列表成员、当前窗口与后台索引都参与使用统计。删除只登记应用拥有的候选路径；有效历史、活动窗口或读取／写入任务仍引用时延后，最后一个使用者释放后再清理。
- `managed_body_`、`session_body_` 不计入可淘汰缓存限额；旧历史引用的正文也不可因缓存限额被清除。派生缓存可重建。
- 正文写入串行、原子替换，连续编辑去重；退出前排空写入。写入中的正文不误判为失效文件。写入失败通过现有文件打开反馈显示，并允许后续重试。
- 启动残留回收只处理生命周期明确的新托管正文与私密分享导出，保守保留最近 24 小时的文件，以免误删在途内容。

## 旧数据处置清单（代码行为与实际数据处置分开）

1. 有可靠 `file:` 来源的旧图片／文本／网页记录在定位时转为原引用；原文件不存在时不回退旧缓存。
2. 自动移除旧外部引用时，`legacyExternalBodyPaths` 中可能是唯一副本的旧正文保留在磁盘；不在启动扫描或容量淘汰中销毁。需要用户单独决定导出／删除这些旧文件。
3. 无可靠原路径的旧正文保持应用托管归属；不反推用户原文件，不做旧协议长期兼容。
4. 新托管正文按历史及活动使用者释放；旧未知孤立 `cached_image/text/web/package` 正文不参与自动容量回收。
5. 本次没有运行开发数据重置、批量旧数据删除、签名／权限修改、提交或推送。测试夹具仅使用测试进程的临时目录与新建的应用托管测试文件。

## 验证记录

- 修改前基线：`xcodebuild test -project foofoil.xcodeproj -scheme foofoil -destination 'platform=macOS' -only-testing:foofoilTests/ContentCacheTests -only-testing:foofoilTests/IncognitoFoilTests`，通过。
- 新增专项：`-only-testing:foofoilTests/FileReferenceLifecycleTests`，首轮 8 项通过；后续补充到 13 项；涵盖改名、坏书签、离线、部分列表、删除／索引竞态、共享正文、剪贴板编辑恢复、无痕与混合表示。
- 缓存与历史聚焦：`ContentCacheTests`、`HistorySearchTests` 及边框／方向键回归通过。
- 完整回归、最终 `./run` 已成功，简中深色设置与历史来源标记已检查；详细真实交互结果见实施计划的末尾交接记录；未实际执行的沙盒重新授权、真实浏览器剪贴板、多窗口拖放、硬件媒体与 Release 验证保留待验证。
- 环境基线诊断：Xcode 的 CoreSimulator 版本提示（macOS 目标不使用该模拟器）和未链接 AppIntents 时的 metadata extraction skipped；新增 Swift 源码警告应全部修正。
