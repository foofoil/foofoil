# Agent terminal v1：S07 原型记录与规格状态

> 2026-10-17。本机开发协议 v1 已实现。Developer ID／公证／Gatekeeper 验收独立保留在 S13；下方早期原型失败记录保留作设计依据。

## 首轮原型记录（历史证据，已由下文第二轮修正）

入口：[独立原型与复现命令](../scripts/agent-terminal-prototype/README.md)。源码为 `Protocol.swift`、`Host.swift`、`Client.swift`，构建及验收脚本为 `build`、`verify.py`。

外部原生 Swift CLI 使用 [NSWorkspace.open(_:withApplicationAt:configuration:completionHandler:)](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:withapplicationat:configuration:completionhandler:)) 向独立沙盒宿主交付两个文件 URL：原文件和请求信封。宿主读取原文件并向同一信封写回结果，CLI 等待确定响应。没有正文传输、正文归档、独立运行时、守护进程、网络服务或产品数据修改。

宿主编译使用 `swiftc -O -swift-version 6 -warnings-as-errors`，使用现有产品 Release entitlements、hardened runtime 和 Apple Development 签名；`codesign --verify --strict` 成功。这只是独立优化构建，**不是 foofoil Release 交付物**，也不是 Developer ID 签名验证。

| 实验 | 结果与边界 |
| --- | --- |
| 首次启动、仅传原路径 | 返回 `NSCocoaErrorDomain/513`，没有获得源文件读取权；信封请求／响应成功 |
| 显式交付原文件 | 读取成功，SHA-256 与 CLI 夹具一致，scope 启动并生成只读书签 |
| 同路径原位改写、原子替换 | 两种更新均读取到新内容 |
| 释放再恢复 | 原型释放自己持有的 scope 和源 URL，read 失败；书签 restore 后读取成功。未证明 OS 隐式授权即时撤回 |
| 退出、新进程恢复 | PID 改变，只重新交付信封；从容器书签读取原文件成功 |
| 删除原文件 | read 返回失败，没有旧正文回退 |
| 额外空窗 | 所有响应中宿主窗口数均为 0；原型未接入产品启动恢复 |
| 前台应用 | 调用前后采样均保持 Codex；未验证连续键盘输入、多屏／全屏 |
| 隐藏应用连续调用 | **失败**：第一次查询回调时 hidden=true，250 ms 后 hiddenAfter=false；再次调用保持 false。客户端已设置 activates=false、addsToRecentItems=false，并按既有隐藏状态设置 hides=true |

自动验收共 13 项：12 项通过、1 项失败，`verify.py` 退出码 1。报告位于被忽略的 `build/agent-terminal-prototype/results.json`。测试只使用本次自建夹具；finally 清理源文件、信封与原型书签并退出原型。

[hides 官方定义](https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration/hides)描述的是启动后隐藏；本机运行中进程的实测不能支持“后续文件交付保留隐藏”的承诺。因此不将这一候选方案固化到产品，不用接收后再次 hide 的办法掩盖可能的窗口闪现。

## 首轮路线比较（历史记录）

| 路线 | 文件授权／启动 | 当前判定 |
| --- | --- | --- |
| NSWorkspace 文件交付 + 信封原位响应 | 已证明独立沙盒首次读取和书签恢复，不需要新增产品权限 | 首轮默认分派隐藏失败；第二轮提前接管并直接发送标准事件后修复，见下文 |
| 本地监听连接 + 显式文件能力交付 | 需要另外验证外部客户端可达性、文件访问能力和冷启动 | 未做原型；Release 没有 network.server，不能直接沿用 Debug 回环测试。不能假设 socket 或路径字符串会带来文件授权 |
| 外部 XPC 服务 | 需要验证服务注册／发现、调用方准入、文件能力传递和分发 | 未做原型；不能把内部模块 XPC 服务作为已有 CLI 服务，也不能以新增权限绕过验证 |

[App Sandbox 官方说明](https://developer.apple.com/documentation/security/app-sandbox)说明网络与文件访问由各自 entitlement 约束；具体替代方案仍须实测，表中未做原型的路线不记为失败或可用。

首轮提出的最小后续实验：将文件访问能力交付与运行中的控制请求分开验证，找到不会触发 LaunchServices 解除隐藏的请求路径，再用 Developer ID 签名的实际产品 Release 证明冷启动、首次读取、同路径替换、关闭释放和普通箔恢复。不得引入正文持久副本或扩大目录授权来规避。

## 分发签名门槛

实际执行：

```sh
security find-identity -v -p codesigning
./package-dmg --sign-only
```

当前本机仅发现 Apple Development 身份（另有同名 revoked 身份），没有 Developer ID Application。打包脚本在任何产品构建／签名前退出 1，报 `未找到 Developer ID Application 证书。` 本次没有申请证书、改变签名配置、沙盒权限、文件关联或以 `--no-sign` 替代分发验收。

2026-10-17 用户确认：Developer ID 签名移入 S13 分发验收；S07 继续使用现有开发签名和正式沙盒权限进行开发验证。用户已确认 H01—H06 完成，本计划接受该前置条件；这里没有重跑或改写独立前置任务的历史记录。

## 第二轮：无干扰文件事件

原型在 `applicationWillFinishLaunching` 注册标准 `kCoreEventClass/kAEOpenDocuments` 处理器，先识别控制信封，绕过 AppKit 会解除隐藏的默认分派。运行中 CLI 直接发送标准打开文档 Apple Event（`noReply`、`neverInteract`，保留系统自动沙盒注解）；冷启动用 NSWorkspace 指定应用和 `--foil-agent` 参数。未引入自定义 Automation 事件、后台服务、网络监听或额外权限。

优化编译、Swift 6 warnings-as-errors、现有 Release entitlements、Apple Development 签名的第二轮原型：**13 项全部通过，退出 0**，包括连续隐藏调用。正式应用对普通打开文档事件转回现有 GUI 打开路径；只有 `.foilrequest` 控制信封走专用入口。冷启动标志抑制普通空窗与批量恢复；应用运行中不经过 LaunchServices 打开流程。

## v1 传输、授权与安装

- 应用将原生 `foil` target 嵌入 `Contents/MacOS/foil`，Debug／Release 均构建；分发脚本对该工具单独签名后签宿主。
- 请求为 UTF-8 JSON 信封，CLI 在 0700 随机临时目录中创建 0600 的 `.foilrequest` 文件；原文件 URL 和信封同批交付。响应原位写回信封。CLI 正常退出清理信封，不传输或归档正文。主应用的传输与原文件准备各使用独立后台串行队列，防止原文件阻塞拖住超时响应。
- 冷启动先 hello，再 authorize，最后执行命令。hello 返回 `protocol_version` 和随机 `run_id`，不返回任何窗口信息。已运行应用通过精确 bundle 路径选择 PID；CLI 默认优先使用自身所在 app，安装副本用 LaunchServices 查找 `com.markonce.foofoil`。`--app`／`FOIL_APP` 可明确指定应用；bundle ID 不符拒绝。应用不可用为 APP_NOT_FOUND，握手不兼容为 PROTOCOL_MISMATCH。
- 默认凭证文件 `~/.local/state/foofoil/session.json`，或 `--session FILE`／`FOIL_SESSION`。CLI 生成 256-bit 随机 secret；以私有锁文件串行化首次创建和运行期换证，凭证文件必须为当前用户拥有的普通文件且组／其他人无访问权限。应用内只保存 secret 的 SHA-256；不写入历史、WindowConfig 或日志。
- authorize 在当前 run 内注册本机凭证，最多 32 个。`--caller` 仅显示来源。不同调用方使用不同私有 session 文件；默认路径共享一个调用方。该机制不隔离能读取同一用户私有文件的恶意进程，不承诺任意同用户进程间的强隔离。
- 设置中的暂停控制阻止新写入及在途提交，查询仍可用；暂停后恢复不会重放已拒绝写入。撤销使当前已注册 secret 在本次运行永久失效，并解除现有窗口归属；不得自动创建新凭证绕过。控制、暂停、凭证授权均属于本次应用运行。重启后 CLI 按新 run_id 换证，原 board_id 无效；普通历史恢复为人工窗口。只读展示策略单独保存为 readOnlyPresentation（SQLite schema 23），用于恢复只读通道、Markdown 资源限制和边框偏好，不包含 board ID、调用方、revision 或凭证；GUI 显式替换内容解除该展示策略。
- `foil install [--directory DIR]` 默认复制原生工具到 `~/.local/bin/foil`，不修改 PATH。旁置 SHA-256 收据只允许替换／卸载上次安装且内容未被修改的工具；同名第三方命令返回 INSTALL_CONFLICT。应用移动后安装副本通过 LaunchServices 重新发现，升级后再次执行新 app 内的 install 更新副本。`foil uninstall` 删除匹配收据的工具与收据，不卸载应用。无需开发目录或语言运行时。

## 请求、顺序与确定响应

正式请求字段：`protocol_version`、`request_id`、`action`、`run_id`、`credential`，可选 `caller`、`board_id`、`path`、`title`、`incognito`、`expected_revision`。show 只接受已交付的本地文件并始终新建；update 必须指定已授权 board，不能改变 title 或 incognito；list 只列该凭证窗口；close 只关闭该凭证窗口。不存在和不属于该凭证的 board 均为 BOARD_NOT_FOUND。

四命令 stdout 均输出 JSON（`--json` 可显式标注），stderr 只输出稳定错误码，失败退出 1；帮助和版本为文本。成功 `status=ready`，失败 `status=failed` 并带 `error`。show／update 返回 board_id 和成功内容 revision（从 1 开始）；close 返回关闭前 revision；list 返回 boards。warning 与 error 分离。

- 去重键为当前运行、凭证、request_id；规范 JSON 请求体的 SHA-256 决定内容是否相同。相同 ID 不同请求返回 REQUEST_ID_CONFLICT。相同请求复用在途或已完成结果；已关闭的旧 show 重试不重建窗口。
- 去重期限为接受后 600 秒。期限外 ID 按新请求处理，可能再建窗口；调用方不得将超期重试当作安全重试。应用重启不保留去重账本或自动重连。
- 所有四命令采用应用接受顺序的全局有界 FIFO；内容准备逐个执行，因此同窗不会逆序覆盖。GUI 关闭／替换、暂停或撤销在准备期间发生时，提交前复查窗口、归属、控制代次、revision 和期限。失败不增加 revision。
- 每个已接受请求在 30 秒后返回 TIMEOUT，排队请求取消；若正在系统 I/O 中，等待 I/O 返回后释放本次 scope 并拒绝过期提交。无法强制打断操作系统阻塞读取，但不会再增加并发准备任务。CLI 每次交换最多等待 35 秒；断连或 CLI 超时不撤回可能已提交的结果。以相同 ID 和相同参数在期限内重试，不自动换 ID。
- 人工关闭、替换、暂停／撤销及期限到达均可使在途写入失效；没有单独面向 CLI 的 cancel 命令。应用退出终止本次运行的全部任务和控制身份。

## 限额与 ready

| 项目 | v1 值与目的 |
| --- | --- |
| 信封 | 32 KiB；最多 4 个事件 URL，正式 CLI 发送最多 2 个 |
| 入站／执行队列 | 各最多 16 个；超额拒绝或未接受并由 CLI 超时报告，不创建无界任务 |
| 去重账本 | 1024 条；保留有效期内记录，不为接纳新请求驱逐有效结果 |
| 同 ID 等待者 | 最多 16 个 |
| 自动化窗口 | 全应用最多 32 个 |
| 创建频率 | 全应用 60 秒最多成功创建 12 窗 |
| 输入文件 | 普通文件最大 16 MiB；目录和非普通文件拒绝 |
| UTF-8 文本／Markdown／SVG | 最大 2 MiB；拒绝无效 UTF-8、文本 NUL、SVG DTD／实体 |
| 光栅图 | 首帧最多 2400 万像素、单边最多 16384；后台 ImageIO 验证并解码，避免压缩小文件引发无界像素分配 |
| 请求 ID／title／caller | UTF-8 分别最多 128／512／128 bytes |

固定上限使低成本测试可以覆盖边界，且单次图片解码和队列占用有界；不是机器无关性能承诺。

文本及代码 ready 表示普通文件已完整有界读取、UTF-8 校验并提交原生只读视图。Markdown 同上，提交时启用仅自包含内容渲染，HTML 导入前移除图片标记并显示本地化不可用提示；不读取或下载图片，响应可含 MARKDOWN_RESOURCES_BLOCKED。富文本排版异步完成，ready 不表示排版或像素完成。

光栅图 ready 表示首帧完成 ImageIO 解码，提交已准备的内存图片。SVG ready 表示 XML 根、无 DTD／实体、大小及布局尺寸（正值且单边 1—16384、最多 2400 万面积）校验通过，原生 NSImage 只作布局占位，不对 SVG 正文解码；已准备字节提交既有无脚本、无外部资源的 WebKit 图片渲染器；不等待 WebKit 绘制。显式同路径 update 使用内容修订更新展示，不依赖 URL 改变。不持久保存图片或 SVG 正文副本。

Agent 文本／代码统一使用原生只读视图，避免 WebKit 代码页替换导致阅读位置重置。Markdown 准备后的富文本任务也纳入 FIFO 背压，避免持续自动更新堆积解析任务。

同类更新保留窗口布局与内容缩放；文本视图保留并截断滚动位置，图像视图用稳定 board 身份保留 ScrollView。类型变化重置内容缩放／阅读位置，但保留窗口位置、大小、置顶、透明度、边框和隐藏状态。读取失败保留旧内存画面；不承诺被覆盖或删除的旧原文件可恢复。

## 错误码

PROTOCOL_MISMATCH、INVALID_REQUEST、INVALID_ACTION、PERMISSION_DENIED、BOARD_NOT_FOUND、CONTENT_UNREADABLE、UNSUPPORTED_CONTENT、CONTENT_INVALID、CONTENT_TOO_LARGE、REVISION_CONFLICT、CONTROL_PAUSED、QUEUE_FULL、WINDOW_LIMIT、RATE_LIMITED、TIMEOUT、NOT_READY。CLI 另有 APP_NOT_FOUND、APP_LAUNCH_FAILED、INVALID_ARGUMENTS、CLI_IO_ERROR、CREDENTIAL_UNAVAILABLE、INSTALL_CONFLICT、INSTALL_FAILED、NOT_INSTALLED。错误诊断不包含正文或 secret。

## 尚待验收

以实施计划的实际测试记录为准。Developer ID、公证、Gatekeeper、干净机器首次启动／安装、正式签名后的书签／授权／升级回归保留到 S13 分发验收。多显示器、全屏 Space、真实存储离线和长时间资源曲线没有证据时不得勾选完成。
