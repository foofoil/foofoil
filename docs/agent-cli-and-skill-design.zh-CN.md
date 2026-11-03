# 浮箔 Agent 操作能力与接入设计

> 日期：2026-11-03。状态：CLI 与接入管理实现已扩展；专项验证与外部验收边界见第 12 节。
> 本文覆盖 CLI 能力扩展、无痕行为、Skill 分发及本机 Agent 接入。除明确标记为“当前实现”的内容外，命令、字段和错误码均为拟议契约，不表示已经可用。本文不授权修改系统权限、自动提交或发布。

## 1. 目标与文档关系

让用户电脑上的 Agent 能发现浮箔、理解内容、操作具体箔，并确认最终结果。用户安装浮箔后，应能通过一次接入操作，让常用本机 Agent 使用同一套能力。

典型任务：

- 展示 Agent 生成的 Markdown、图片或代码，并持续更新同一箔。
- 找到已打开的文档，读取目录，跳转章节，读取内容并确认阅读位置。
- 查询音频当前曲目和进度，播放、暂停或跳转，确认实际状态。
- 无痕打开资料，在保持无痕的情况下打开派生内容。
- 查询和开启文件搜索等已有配置，了解仍需用户完成的系统授权。

本文是现有只读展示接口之后的扩展设计，不重写其历史实施记录：

- [Agent 桌面呈现能力方案](foofoil-agent-desktop-terminal.md)
- [协议 v1 与通信验证](agent-terminal-protocol-v1.zh-CN.md)
- [既有实施记录](foofoil-agent-desktop-terminal-implementation-plan.md)
- [当前中文使用说明](agent-terminal-usage.zh-CN.md)
- [终端控制设计](foofoil-terminal-control-design.zh-CN.md)

既有文档中的“首版不支持”是原阶段边界；本文新增能力按后续阶段实施。正式交付某项能力时，再同步使用说明与协议文档，不能将设计直接写成已支持能力。

## 2. 当前实现基线

以下为 2026-11-03 本轮实现后的本机开发状态。静态 schema 描述命令契约，窗口可用性必须查询运行宿主。

| 领域 | 已实现入口 | 边界 |
| --- | --- | --- |
| 所属展示 | show、update、list、close | 保留原 board ownership、revision、去重与授权 |
| 身份与状态 | list --scope all、inspect、capabilities | 运行期句柄带 run 前缀；快照含内容／状态版本、只读、加载错误、位置与屏幕坐标。窗口列表每页最多 20 项，续页绑定版本 |
| 打开与结果 | open FILE／--url／--directory／--clipboard、wait | open 返回 operation；wait 可查询指定操作或窗口最近操作，CLI 有界轮询。记录最多 128 条、保留 600 秒；未完成操作最多观察 300 秒；关闭、替换与失败单独报告。Quick Look 没有可靠完成信号时返回 COMPLETION_UNOBSERVABLE，不冒充 ready |
| 读取与导航 | read、outline、items、search、navigate、items select | 当前内存文本；PDF 指定页；当前 WebKit／EPUB 渲染正文；已有 OCR；终端保留输出。Unicode scalar 分页、20 项列表分页、版本校验。搜索不移动位置；PDF／文本定位与导航贡献复用原生入口，异步导航操作查询实际 current／selection |
| 无痕 | 所有 open 来源、history open、show、terminal create、set incognito | 历史无痕副本不 touch 原记录；转换报告历史动作，重复 setter 报 unchanged；收藏拒绝；派生入口沿用既有继承 |
| 媒体与窗口 | media status／play／pause／seek／next／previous／volume／mute／mode／select；set zoom／navigator；screens、window frame、focus | 复用当前媒体控制器与协调器；不支持的能力显式拒绝。播放、暂停、seek、音量与静音可查询操作结果。frame 返回屏幕可用区左上原点的实际坐标 |
| 配置与权限 | config list／get／set、permissions status、settings open | 显式白名单覆盖本机文件搜索、Apple Music、启动、文档默认主题与字号、历史清理、媒体步长与自动隐藏；不写任意 defaults、不自动开启依赖、不发起系统授权 |
| 历史与导出 | history search／open、export original／png | 历史有界元数据；原始导出复用 contentSavePayload，图片导出复用本进程视口捕获；同目录暂存后原子提交，默认不覆盖。压缩包多节点导出继续使用 GUI 原有限额管线，CLI 尚不提供多节点导出 |
| 自说明与接入 | --help、help、--version、guide、schema、doctor、agent setup／status、skill install／check／update／uninstall；Agent 接入设置页 | 离线说明与参数白名单共用 catalog；中英文指南；Skill 薄入口；安装清单、摘要、锁与原子写入；冲突保护；CLI 稳定路径；检测不等于真实发现 |

### 2.1 尚未完成的外部验收及明确边界

- 当前未执行 Codex／Claude Code／Cursor 新会话中的真实发现与调用；仅核对官方目录规则及临时目录安装生命周期。Codex 与 Cursor 共用 `~/.agents/skills`，Claude Code 使用 `~/.claude/skills`。GUI Agent 的 PATH 需要在对应环境验证。
- 未执行 Developer ID 签名、公证、干净机器和正式分发验收，未执行全套测试。
- 不可靠的系统预览完成信号、不支持提取的内容、尚无 OCR 结果均明确返回边界；read 不启动隐式 OCR 或递归解包。
- 没有新增任意系统权限写入、压缩包批量导出协议、MCP、输入注入或远程桥接。文档默认主题与字号仅影响新建箔，既有样式不被重写。

关键源码为 `AgentCLI/Foil.swift`、`AgentTerminal/AgentCommandCatalog.swift`、`AgentProtocol.swift`、`AgentTerminal.swift`、`ApplicationControlService.swift`、`AgentApplicationCommands.swift`、`AgentIntegration.swift` 与 `AgentIntegrationSettingsView.swift`。

## 3. 产品与技术原则

- 浮箔负责内容呈现与已有内容操作，不负责模型推理或任务编排。
- 原文件继续直接引用；不为 Agent 接入引入正文归档、云端处理或网络监听。
- 按能力组织操作：媒体控制、目录、搜索、正文读取可以跨内容类型复用。
- 宿主只使用协商能力与不透明 ID，不在通用控制入口解析 Hi-Fi 等模块私有命令。
- 查询不抢焦点；更新不重新显示隐藏箔；用户关闭后不自动重建。
- 使用明确目标状态，如 pause、mute true、incognito true，减少 toggle 导致的重试错误。
- 能力发现不是授权；Skill 是说明文件，不授予 shell、文件或应用控制权限。
- 默认输出有界结构化数据；大内容分段读取或导出到文件。

## 4. 身份、能力和状态模型

### 4.1 身份

- `window_id`：本次应用运行中的窗口身份，作为普通操作的主要目标。
- `content_id`：当前内容身份，内容替换后可能变化，不作为稳定窗口句柄。
- `board_id`：Agent 所属展示箔身份，保留现有归属检查及 update 语义。
- `run_id`：应用运行身份。重启后旧窗口句柄失效，返回明确错误，不自动认领或重连。
- `item_id/target_id`：目录、章节、曲目、压缩包节点等不透明定位标识；有效期由返回的内容版本或导航版本限定。

兼容阶段保留原命令的 ID 含义，响应显式给出相关身份。新命令统一接受 window ID，不通过标题猜目标，不将 UUID 外形作为 ID 类型判断依据。

### 4.2 能力发现

```sh
foil capabilities
foil capabilities WINDOW_ID
```

应用级查询返回协议版本、命令 schema 和安装内容模块支持的能力；窗口级查询返回当前内容实际支持的能力、参数范围、是否可用及原因。

例如具备 media.seek 能力，但未知时长、直播流或设备初始化中可能暂时不可用。不能只看 type=audio 就假设所有媒体命令都能执行。公开产品概念是内容能力，不提供用户安装扩展或管理 Registry 的入口。

### 4.3 快照与版本

增强 inspect，返回：身份、类型、标题、来源描述、visible、incognito、只读状态、窗口属性、加载状态、可用能力及类型专属摘要。默认不带正文。

区分：

- `content_revision`：正文或当前内容发生变化。
- `state_revision`：可观察的操作状态变化，不要求对每次播放时间采样递增。
- `observed_at`：快照采样时间。

读取和导航使用内容版本防止定位串到新内容；播放进度不能导致正文分页失效。列表分页游标必须绑定对应内容／队列版本，失效时要求重新查询。

## 5. 读取、目录、搜索与加载完成

### 5.1 命令

```sh
foil inspect WINDOW_ID
foil read WINDOW_ID --source original --offset 0 --limit 8000
foil read WINDOW_ID --source rendered --page 3
foil read WINDOW_ID --source ocr
foil read WINDOW_ID --source terminal --tail 100
foil outline WINDOW_ID
foil items WINDOW_ID --limit 50
foil search WINDOW_ID "关键词" --limit 20
foil wait WINDOW_ID --until ready --timeout 30
```

| 内容 | 可读信息 | 定位方式 |
| --- | --- | --- |
| 文本／代码／Markdown | 当前加载正文、源码、标题结构 | 行、标题 target ID、阅读比例 |
| PDF | 页数、页文本、书签、当前位置 | 页码、书签 target ID、搜索结果 |
| EPUB | 目录、章节文本、阅读位置 | 章节 target ID、阅读比例 |
| 图片 | 尺寸、格式、OCR 状态与结果 | OCR 结果；图像导出独立处理 |
| 音视频 | 元数据、播放状态、轨道与队列 | 时间、item ID |
| 目录／压缩包 | 已加载树节点、选择状态 | item ID；展开节点显式请求 |
| 终端 | 有界保留输出与会话状态 | 尾部行、文本偏移 |
| 网页／系统预览 | 可提取的正文、页面信息 | 按实际实现能力开放，无法提取时明确报告 |

`original` 定义为当前已加载内容的原始表示，不意味着悄悄重读已被外部修改的磁盘文件；如需重读，应增加显式 refresh 并推进内容版本。`rendered` 是可提取的显示文本，不承诺与视觉排版逐像素一致；可见视口可作为后续独立读取范围。

分页响应包含内容版本、偏移单位、截断标记、下一段游标与提取状态。文本偏移采用 Unicode scalar 索引并在 schema 中声明；limit 是 scalar 数量，另设 UTF-8 字节上限。页码和展示行号从 1 开始。时间单位为秒、比例范围为 0～1。

无文本的扫描页、尚未运行的 OCR、提取失败和不支持是不同状态。昂贵提取在后台有界执行；read 不隐式启动无限 OCR 或递归解包。目录／压缩包默认只返回已读取节点，展开和扫描范围必须显式指定。

search 返回匹配片段与可跳转 locator，不自动改变当前阅读位置。终端读取仅覆盖当前实际保留输出，不承诺完整任务日志。

### 5.2 异步结果

open、加载、OCR、设备切换等操作区分 accepted 与完成：

- 同步完成：直接返回新状态。
- 异步受理：返回 operation ID、关联窗口和当前状态。
- `foil wait --operation OPERATION_ID --timeout 30` 等待指定操作。
- ready 表示对应操作完成，不只是窗口存在；失败返回可定位的原因。

operation 记录按时间和数量限制，应用重启后失效。CLI 等待超时不等于操作取消，应报告是否仍在进行，允许再次查询。不能把窗口 ready 当成任意旧操作的成功证据。

## 6. 类型操作与窗口控制

### 6.1 媒体

```sh
foil media status WINDOW_ID
foil media play WINDOW_ID
foil media pause WINDOW_ID
foil media seek WINDOW_ID --to 90
foil media seek WINDOW_ID --by 15
foil media next WINDOW_ID
foil media previous WINDOW_ID
foil media volume WINDOW_ID 0.5
foil media mute WINDOW_ID true
foil media mode WINDOW_ID sequential-loop
foil media select WINDOW_ID --item ITEM_ID
```

统一普通音频、视频、Hi-Fi 与 Apple Music 的宿主控制入口。复用已有播放控制器及播放名额协调，不能绕过独占设备释放或同时启动多路输出。

状态包括播放／暂停／缓冲／失败、当前时间、时长、当前项目、音量、静音、模式与支持能力；未知数值返回 null。不同后端不支持的操作返回 capability 错误，不伪装成功。具体曲目和设备可能受系统授权、地区和设备状态限制。

字幕载入、显示、延迟、音轨选择和输出设备切换列为后续能力；设备操作须报告是否影响系统其他音频。

### 6.2 文档与列表

```sh
foil navigate WINDOW_ID --target TARGET_ID
foil navigate WINDOW_ID --page 12
foil navigate WINDOW_ID --line 120
foil navigate WINDOW_ID --progress 0.5
foil items select WINDOW_ID --item ITEM_ID
```

使用既有导航和搜索定位逻辑，不模拟键盘点击。跳转结果返回实际落点及内容版本。导航节点失效返回 STALE_TARGET，不按同名标题自动寻找替代节点。文档缩放和阅读位置操作不得修改原文件。

### 6.3 窗口属性

```sh
foil set WINDOW_ID pinned true
foil set WINDOW_ID title "参考资料"
foil set WINDOW_ID border false
foil set WINDOW_ID zoom 1.25
foil set WINDOW_ID navigator visible
foil window frame WINDOW_ID --screen SCREEN_ID --x 100 --y 100 --width 800 --height 600
```

frame 使用指定屏幕可用区域左上角为原点的逻辑点坐标，响应返回实际钳制后的 frame 与屏幕 ID。屏幕查询、缩放范围和最小尺寸进入 schema。reveal 与显式 focus 分开描述，不能让普通查询激活应用。

终端本期只补状态和输出读取；输入、按键注入、执行完成标记单独设计，不把创建时 startup script 扩展成通用无回执执行接口。

## 7. 无痕能力

### 7.1 接口与继承

```sh
foil open FILE --incognito
foil open --url https://example.com --incognito
foil open --directory /path --incognito
foil open --clipboard --incognito
foil history open HISTORY_ID --incognito
foil set WINDOW_ID incognito true
foil set WINDOW_ID incognito false
foil list --scope all --incognito
```

所有新建内容入口统一接受 incognito；show、terminal create 保留现有选项。inspect 和窗口列表返回 incognito。筛选参数只筛选窗口，不改变默认 list 的所属范围。

无痕历史打开建立独立副本，不更新原记录访问时间。目录项目、包内预览以及从当前内容派生的新箔继承无痕；已有更严格规则继续生效，例如 Markdown 链接本就使用无痕新箔，不能被普通父箔降级。显式独立 open 未指定选项时沿用普通打开默认，不依赖当前焦点。

### 7.2 转换与持久化

核实当前 `toggleIncognitoMode()`：

- 普通转无痕删除当前箔历史，保护窗口仍在使用的托管正文。
- 收藏历史的箔禁止转无痕。
- 无痕转普通允许重新保存历史并配置终端快照保存。

CLI 提供目标状态 setter，内部复用转换逻辑。已处于目标状态时直接返回，不能再次 toggle。失败使用结构化错误，例如 HISTORY_FAVORITED，不只显示 toast。

响应报告 incognito、历史动作（created／removed／unchanged）、恢复参与状态以及终端输出持久化状态。转换不清除其他副本、下载、导出文件或系统记录，不能声称已擦除所有痕迹。

无痕正文可以被获授权 Agent 显式 read；无痕不自动扩大其读取权限。inspect 默认不附正文。浮箔不记录无痕正文日志，但无法承诺 Agent 自己不保存命令结果。下载、导出、终端脚本文件继续按实际磁盘行为处理。

## 8. 配置与系统权限

```sh
foil config list
foil config get search.local-files.enabled
foil config set search.local-files.enabled true
foil config set apple-music.library.enabled true
foil config set search.apple-music.enabled true
foil permissions status
foil settings open --section audio
```

配置使用显式白名单，返回类型、默认值、当前值、范围、作用域、依赖、是否立即生效、是否需要重启。先覆盖已有文件搜索、音乐资料库和搜索、启动行为、文档默认样式、媒体步长与自动隐藏、历史自动清理。

调用已有设置服务并触发 UI 同步，不开放任意 UserDefaults 写入。配置依赖默认返回 unmet prerequisites，除非命令明确要求，不自动开启其他选项；需要组合设置时验证全部参数后一次提交。

功能关闭、未获系统授权、受系统限制、权限无法判定分别报告。permissions status 不触发弹窗；需要交互时返回 action_required，用户可显式打开对应设置或发起授权。CLI 不绕过 macOS 权限。

## 9. 打开方式、历史与导出

后续补齐 URL、目录、剪贴板、历史搜索／打开与导出：

```sh
foil history search "关键词" --limit 20
foil history open HISTORY_ID
foil export WINDOW_ID --format png --output /absolute/path/view.png
foil export WINDOW_ID --format original --output /absolute/path/source
```

历史查询默认只返回元数据和有界片段，不包含当前无痕窗口。普通历史打开复用已有身份和访问行为；无痕副本遵循第 7 节。

导出区分视口图片与原始内容，遵循现有格式限制；不支持另存的内容不能通过 CLI 绕过。默认不覆盖目标，显式 overwrite 才允许覆盖。输出文件由用户／调用方指定，返回绝对路径、格式与结果。压缩包导出复用现有路径校验、限额和暂存提交，不能另开无界提取路径。

## 10. 本机 Agent 接入

### 10.1 三层结构

```text
Agent 经 Skill 发现，或由用户指明 foil 入口
               ↓
foil 自说明与 CLI → 现有授权／IPC → 宿主内容能力
```

CLI 同时提供执行能力与主要操作说明；Skill 是可选的发现与触发入口；接入管理负责安装、更新和排查。未安装或不支持 Skill 的 Agent，只要能执行本机命令，也应能从 `foil guide` 开始完成全部已开放流程。远程／容器中的 Agent 仅安装 Skill 不会自动获得本机访问能力。

首版不引入常驻桥接服务。仅能调用工具的客户端后续可通过 MCP 适配同一服务，保留授权、暂停、无痕和结果契约，不形成第二套行为。

### 10.2 用户流程

设置增加“Agent 接入”：CLI 状态、各 Agent 的安装状态、版本、检测原因、检查与修复、重新检测、自定义路径，以及试用提示词。

首次提供“启用 Agent 接入”，展示将安装的 CLI 和 Skill 路径，用户选择后一次完成。后续更新已管理安装不重复询问；新增 Agent 提供重新检测。安装到某目录不代表该 Agent 已加载，界面须区分“文件已安装”“需要新会话／重新加载”“已验证可调用”。

默认用户级安装，项目级作为高级选项。不向所有项目写 AGENTS.md，不改 Agent 全局工作流策略，不自动降低执行权限。

### 10.3 拟议管理命令

```sh
foil agent setup
foil agent status --json
foil skill install --agent codex
foil skill install --detected
foil skill install --path /custom/skills/foofoil
foil skill check
foil skill update
foil skill uninstall --agent codex
foil guide
foil doctor --json
```

`install --detected` 为检测到且用户选择的目标首次安装；`update` 刷新已有浮箔管理的安装。无人值守安装必须显式指定目标或 --detected，不在非交互调用中挂起等待选择。

保留当前 install/uninstall 的 CLI 安装语义；agent setup 组合调用安装流程，避免旧命令静默扩大写入范围。

### 10.4 发现规则与安装归属

采用“通用接入为主、少量专用适配兜底”，不把支持范围做成封闭的 Agent 名单：

| Agent 条件 | 接入路径 | 是否需要专用适配 |
| --- | --- | --- |
| 支持已验证的通用 Skill 目录 | 安装一份共享 Skill | 无需重复安装 |
| 支持 Skill，但目录或格式不同 | 同一正文写入专用发现目录 | 仅安装与发现规则 |
| 不支持 Skill，但能执行本机命令 | 用户指明 `foil guide`，通过自说明探索 | 不需要执行协议适配 |
| 只能调用工具 | 后续 MCP 适配 | 客户端注册与工具传输适配 |

Codex、Claude Code、Cursor 是首批集成验证对象，不是唯一可用客户端。检测不到 Agent 不等于不能使用浮箔；界面应保留通用接入、自定义目录和复制启动提示词。新增 Agent 通常只增加目录规则与验证，不改变 CLI、宿主协议或 Skill 正文。通用目录的实际覆盖范围按客户端规则验证，不以文件存在推定兼容。

- 通过适配表维护各 Agent 的发现目录、自定义根目录和刷新方式，随实际官方规则验证。
- 优先支持当前用户常用的 Codex、Claude Code、Cursor，并提供标准 Agent Skills 目录和自定义路径；不承诺一个路径覆盖所有 Agent。
- 区分“检测到配置目录”“检测到可执行程序”“已验证支持 Skill”，不扫描用户聊天正文。
- 共享目录已经覆盖的 Agent 不重复写同名 Skill；检测项目级同名覆盖时明确提示优先级风险。
- 安装清单存入应用现有支持目录，记录路径、版本、摘要、归属和安装时间，不放凭证。
- 写入使用临时文件与原子替换；部分失败逐项报告，不声称全部成功。
- 同名非浮箔文件或用户改过的内容返回冲突，不静默覆盖；保留用户内容，允许指定其他路径。
- 更新／卸载仅处理浮箔管理且摘要符合预期的文件。共享物理安装仍被其他接入引用时保留文件。
- 不默认使用符号链接；真实文件便于兼容不同 Agent 的目录加载与沙盒约束。

CLI 必须有稳定安装位置，诊断同时检查 PATH 和绝对路径。GUI Agent 的环境可能与终端不同，不用当前 shell 的 command -v 成功代替目标 Agent 验证。应用移动、升级和 CLI 副本版本落后时给出明确修复路径。

### 10.5 CLI 自说明作为主要说明来源

自说明承担“已知 foil 后如何使用”的任务；Skill 承担“发现浮箔及何时使用”的任务。命令能自说明，不意味着 Agent 会主动遍历 PATH 发现它，因此仍提供 Skill 安装，但不将其作为执行前置条件。

| 拟议入口 | 内容与边界 |
| --- | --- |
| `foil --help` | 简短用途、主要命令与进一步探索入口 |
| `foil help media` | 主题或命令的语义、参数、单位和示例 |
| `foil schema [COMMAND]` | 机器可读参数、必填项、互斥条件、范围、返回结构及错误 |
| `foil guide [TOPIC]` | 面向 Agent 的完整操作流程；按阅读、媒体、无痕、配置、排错等主题展开 |
| `foil capabilities [WINDOW_ID]` | 运行应用与指定箔实际支持的能力及当前可用性 |
| 错误响应 | 稳定错误码、恢复提示和必要的下一步查询入口 |

`--help`、help、schema、guide 和本地 `--version` 必须离线可读，不启动应用、不创建窗口、不要求凭证，也不依赖网络。capabilities 的运行时部分需要连接应用；静态 schema 不得被描述为当前窗口已支持的能力。

不带参数的 guide 输出有界的起步流程与主题索引，不一次输出全部手册。Agent 可以只阅读当前任务需要的主题；具体命令帮助不反复附带全局指南。未知命令返回错误和有效探索入口，不能悄悄成功退出。schema 使用稳定字段名和版本，禁止混入本地化提示文本破坏 JSON；自然语言指南可本地化。

本地说明、参数验证与命令 schema 应复用同一份命令描述，减少漂移。运行时能力另由宿主确认；每个示例在对应能力交付时验证可执行。错误中的下一步建议使用固定模板与结构化字段，不把正文、标题或文件名当成可执行命令拼接。

无需 Skill 的最短使用路径为：

```text
用户：用浮箔无痕打开这份文档；先运行 foil guide 了解接口。
Agent：读取指南 → 查询能力 → 打开 → 等待加载 → 查询／操作 → 确认结果。
```

### 10.6 Skill 内容与版本

安装一个短小的 `foofoil/SKILL.md`，只保留发现入口、必要约束与指南引导：

1. 描述何时使用：用户要求用浮箔展示、阅读、导航或控制内容。
2. 首次执行 `foil guide`，再按任务读取具体主题。
3. 提醒查询目标与能力、操作后确认结果、尊重用户关闭和无痕语义。
4. 连接失败时引导运行 `foil doctor --json`。

完整参数、重试规则、内容限制与工作流保存在 CLI 内置指南，不在每份 Skill 中复制。Skill 不写“所有任务必须用浮箔”等全局接管指令。所有 Agent 使用同一正文，适配层只处理安装路径和必要的格式差异。

`foil skill` 命名空间专门用于安装、检查、更新与卸载 Skill；指南统一使用 `foil guide`。本文早期提案中的裸 `foil skill` 尚未发布，无需为其新增兼容别名；若后续发现已有实现或发布，则先核实再确定迁移方案。

`--version` 输出本地构建与协议信息，连接运行应用后再核对版本与能力。CLI、内置指南和安装 Skill 入口记录版本；不兼容时明确失败并提示更新，避免按新说明调用旧二进制。Skill 入口版本与 CLI 功能版本分开比较，指南变化不必机械重写所有入口文件。

## 11. 协议、错误与资源限制

沿用现有本机 socket／文件交付与授权流程。现有 board ownership 继续只约束所属展示操作；新窗口操作遵循现有应用控制授权，不把 caller 名称当安全边界。

- 扩展 hello capability 协商；缺失能力不能用猜测命令降级。
- 兼容字段可增量扩展；破坏性改变必须明确调整协议，实施时确定版本，不把本文当成已发布 v2。
- 成功响应含新状态或 operation ID；错误包含稳定 code、可读信息、retryable 及必要恢复信息。
- 建议错误分类：不支持能力、加载中、内容加载失败、陈旧定位、版本冲突、权限不足、需用户操作、配置依赖、安装冲突。
- 沿用 request ID 去重，特别覆盖 next、相对 seek、转换和导出。超出去重窗口后不得承诺重复请求只执行一次。
- 当前信封上限 32 KiB；正文／目录必须控制编码后大小，默认响应应留出元数据余量。大结果走分页或文件，不直接全局放宽上限。
- 查询不得默认泄漏正文、凭证、环境变量或压缩包密码；日志只记录必要元数据，无痕读取结果不写应用日志。
- 读取和提取离开主线程，AppKit 变更在主线程；高频状态查询不能被长时间后台解码阻塞。
- 暂停／撤销应覆盖新增写操作和正在准备的提交；只读状态能否继续查询遵循现有控制策略，并为正文读取明确测试边界。

## 12. 实施阶段与验收

A～F 的本机接口均已有实现，交付范围与后端边界见第 2 节。完整产品验收仍包括真实 Agent 会话、设备和分发环境；不得将专项测试等同于全部验收。

| 阶段 | 交付内容 | 核心验收 |
| --- | --- | --- |
| A（本机实现） | 参数一致性、版本、身份、能力、加载状态、wait | open 失败可观测；重启旧 ID 失效；accepted 不冒充完成 |
| B（按后端能力实现） | read、outline、items、search 与文档导航 | 中文分页不破损；定位不串内容；无文本与未提取可区分 |
| C（接口实现） | 统一无痕接口与转换 | 无痕不恢复；转换删除对应历史；收藏拒绝；派生继承 |
| D（接口实现） | 媒体与窗口属性 | 各后端按能力响应；暂停／seek 可确认；独占交接不绕过 |
| E（白名单与安全导出实现） | 配置、权限状态、打开方式、历史和导出 | 配置 UI 同步；权限不伪造；导出不误覆盖 |
| F（管理实现，真实会话待验收） | CLI 自说明、一键接入、Skill 与 doctor | 有／无 Skill 均可完成任务；干净环境验证安装、发现、调用、更新、冲突和卸载 |

阶段 C 的 incognito 快照与统一打开参数应在 A 中预留，并可随 A 提前交付，不能等全部类型控制完成才支持无痕。

### 12.1 已执行的验证与边界

实施过程中运行了 `AgentTerminalTests` 针对性测试组，最近一次通过，覆盖文本 Unicode 分页与版本失效、目录分页与版本失效、导航动作派发、无痕转换和窗口属性等；运行过 `./run` 构建并启动 Debug 应用。此前一次历史路径断言因 `/var` 与 `/private/var` 的符号链接表示不同而失败，测试已改为比较解析后的路径，并在后续测试中通过。

本轮另增加接入生命周期、操作完成／失败／关闭、目录选择不使结构版本失效、Unicode 搜索及拒绝覆盖测试。具体最后验证结果记在下方；以下跨后端、真实 Agent 会话与分发清单仍为外部验收要求。

### 12.2 专项验证清单

- CLI：参数互斥、值范围、JSON 稳定性、请求重试、错误退出码。
- 自说明：未启动应用／无凭证／离线时 help、schema、guide 可读；逐主题输出有界；schema 与参数验证一致；示例有效；运行时能力未被静态说明冒充。
- 状态：异步成功／失败、超时后查询、窗口关闭、内容替换、应用重启。
- 读取：Unicode、分页边界、响应字节上限、提取失败、无痕日志、权限拒绝。
- 导航：重名章节、过期 item ID、越界页码、缩放后的实际阅读位置。
- 媒体：普通音频、视频、协商媒体与 Apple Music；不支持 seek／volume 的状态；设备释放。
- 无痕：原本普通／无痕、收藏历史、托管正文、多窗口引用、终端快照、历史副本和派生打开。
- 安装：目标不存在、重复安装、自定义目录、用户修改、共享目录、多版本、应用移动、只读目录、部分失败和卸载。
- Agent：首批目标分别在新会话中验证 Skill 发现与一次真实 CLI 操作；另用未安装 Skill 的会话验证从 `foil guide` 完成任务。通用共享目录只安装一份，专用目录按需补装；不将文件写入成功当作集成通过。
- 分发：Debug 与正式沙盒构建分别验证 CLI、文件交付、授权和安装路径；签名／公证／干净机器验证仍遵循既有发布门槛。

应用代码实施后按仓库要求运行相关构建、专项测试和 `./run`；全套测试按仓库既有授权要求执行。仅修改本文档时不需要启动应用或运行应用测试。

## 13. 行业参考与取舍

核对日期：2026-11-03，外部产品行为可能变化。

- [ego(lite) Quick start](https://www.egolite.ai/document/en/docs/quick-start)：首次启动检测 Agent 并写入 Skill。借鉴应用级接入和低操作成本；浮箔对实际目标路径与写入范围给出可见结果。
- [GitButler Agent setup](https://docs.gitbutler.com/ai-agents/getting-started)：向导选择 Agent、范围和指令并预览写入。借鉴接入检查与安装管理，不引入版本控制工作流策略。
- [GitButler skill 管理](https://docs.gitbutler.com/commands/but-skill)：安装、检查、更新；其 --detect 主要刷新已有安装，浮箔将首次检测安装与更新明确分开。
- 本机 ego-browser 的 Skill 入口要求执行 `ego-browser skill` 获取当前程序指南。借鉴短入口与内置指南同步，避免每个 Agent 维护完整副本。

首版交付聚焦可自说明的 CLI + 可选薄 Skill + 一键接入 + 诊断修复；MCP、远程桥接、事件订阅、批量事务和工作区布局模板后置。有明确使用需求后再扩展，不预建常驻基础设施。

### 12.3 本轮实现说明

- 运行 `AgentTerminalTests` 与 `AgentIntegrationTests` 专项测试；安装测试全部使用临时 home，不改本机 Agent 配置。
- 官方目录规则核对：[Codex](https://learn.chatgpt.com/docs/build-skills)、[Claude Code](https://code.claude.com/docs/en/skills)、[Cursor](https://cursor.com/docs/skills)。共享目录覆盖按官方说明合并；不推断客户端已实际加载。
- 协议保持 v1 信封，使用 `application-control-v2` 能力协商新增命令；schema 版本为 2。CLI 连接旧宿主时明确拒绝。
- 未自动提交、推送或发布。GitButler 当前仓库缺少默认 target，创建会话分支亦被拒绝，未运行 setup 更改仓库配置。

本轮最终验证记录：

- `AgentTerminalTests` 与 `AgentIntegrationTests`：28 项通过。
- 安装归属最后修订及相关 `DocumentThemeTests`、`ContentSavingTests`、`DocumentReadingPositionTests`：47 项通过（含重复的 4 项接入测试）。
- `scripts/verify-agent-cli.py`：48 个命令的离线 schema/help、10 个指南主题、版本／doctor 和非法参数矩阵通过。
- `scripts/verify-agent-control.py`：真实 Debug CLI 的无痕打开／等待、Unicode 读取搜索、窗口与屏幕坐标、拒绝覆盖、网页读取与 WebArchive、加载失败、配置／权限查询通过；临时文件与测试窗口已清理。
- 真实 CLI 首轮发现网页读取依赖搜索栏初始化，已改为显式绑定当前正文视图，并在后续真实检查中通过。
- Agent 接入设置中文亮色布局已检查；原生文档主题测试覆盖亮／暗色颜色。未在系统暗色模式下手动检查接入页。
- 按要求运行 `./run` 构建、嵌入内容模块并启动 Debug 应用，检查进程可执行路径。Xcode 的 CoreSimulator 版本不匹配诊断与无 AppIntents 依赖的 metadata 提示来自工具链；macOS 构建与上述测试通过，未新增 Swift 警告。
- 未执行全套测试、真实三客户端新会话集成和正式分发验收。这些事项仍保持未验收，不能据本轮记录宣称整份计划的所有验收已经完成。


### 12.4 接入目标扩充与状态文案

新增 OpenCode（v1/v2）、Pi、OMP、WorkBuddy、Qoder（含 CN）、Kimi Code、ZCode、Zed Agent。接入规则集中在 `AgentIntegration.adapters`，可供 CLI、schema、检测与设置共用。OpenCode v1/v2 用同一目录和归属，保留版本别名；支持通用目录的 Agent 共用一份实体文件。

“尚未安装”原意为浮箔 Skill 未安装，现改为明确的“浮箔 Skill 尚未安装”；另外显示应用／命令检测、仅配置、未检测到三类状态，避免将检测失败等同于程序未安装。更新、用户修改、外部同名文件和不可读状态分别展示。详细路径、资料来源与机器字段见 [当前 CLI 参考](agent-cli-reference.zh-CN.md)。

本次扩充验证：`AgentIntegrationTests` 8 项通过；离线 CLI 检查覆盖 48 个命令 schema/help 与 10 个指南主题，并检查 `agent status` 新目标及独立状态字段。已运行 `./run`，核对 Debug 可执行路径，在中文亮色设置页检查新增条目、独立状态文案和长列表滚动。没有向真实 Agent 目录安装 Skill，也未声称完成各 Agent 的真实新会话调用验收。


### 12.5 检查接入状态的可见反馈

原“检查安装”只刷新状态，但将结果写在长列表底部，状态未变时容易被误认为未响应。现改为“检查接入状态”，后台执行目录／摘要检查，按钮旁显示进度、完成时间与摘要；共享 Skill 按目录去重统计。另说明 Skill 是 Agent 读取的 SKILL.md 指引，直接运行 foil CLI 不依赖它；安装按钮明确命名“安装 CLI 和所选 Skill”。接入专项 8 项通过，最终构建无新增 Swift 警告；已在 Debug 中文设置中真实点击，确认结果立即出现在按钮附近。


### 12.6 简化为即时开关

以此节替代 12.4～12.5 的选择／手动检查 UI：每项开关直接安装或移除对应 Skill；进入页面自动检查并在页面可见时定时刷新。移除手动检查、长报告、批量操作、自定义路径输入与试用按钮，安装时自动准备 CLI。共享目录的开关同步，关闭移除整份共享文件，避免某行显示关闭但文件仍在；CLI 管理命令仍保留原引用语义。错误只显示在相关行，操作失败后回到实际状态；用户修改和外部同名文件仍受保护。已加载的 Agent 会话可能需要重新加载，此操作不绕过客户端的发现与权限规则。

本次验证：`AgentIntegrationTests` 11 项通过，新增临时目录中的即时开关、共享目录同步、独立目录保留、冲突回滚与外部安装／删除刷新测试。已运行 `./run` 并检查 Debug 设置页：完整 Agent 列表、开关和简短说明均正常，页面不再包含手动检查或批量操作按钮。自动检查不修改开关之外的安装选择。


### 12.7 共享安装合并为“通用”

设置将实际使用同一路径的 Agent 合并为一个“通用”开关，注释从目录规则自动列出 Codex、Cursor、Pi、OMP、Kimi Code、ZCode、Zed Agent。Claude Code、OpenCode v1/v2、WorkBuddy、Qoder、Qoder CN 保持独立条目。沿用即时安装／移除及自动检查行为，CLI 的 Agent 名称与安装接口保持原义。


### 12.8 CLI 安装检测、重装和首次默认

设置增加独立命令行工具区域，自动检查已管理副本、可执行性和当前应用环境的 PATH，分别提供安装／重新安装按钮。CLI 缺失或不可用时禁用 Agent 开关并提示先安装。首次从设置安装 CLI 成功后自动开启“通用”，重装及删除后再装不覆盖用户后续关闭的选择。同名未知文件仍受保护，字节完全匹配当前应用内 CLI 的已知副本可在显式重装时接管。通用注释末尾增加“等”，避免把支持范围误读为封闭名单。


本次验证：接入专项 16 项通过，覆盖 CLI 缺失时开关禁用、首次设置安装默认开启通用、关闭后重装／删除后再装不重置选择、PATH 遮蔽、不可执行文件、未知文件保护、已知外部副本和匹配符号链接重装。已运行 `./run`，核对 Debug 进程路径，并在真实设置页点击“重新安装”：状态变为“已安装”，显示完成反馈，已有 Agent 开关选择保持不变。通用成员说明以“等”结尾。


### 12.9 帮助命令一览与设置提示

设置的命令行工具注释增加“命令一览”，复用帮助菜单打开／刷新对应帮助箔；路径前明确标注“命令安装位置”。中英文帮助补齐读取导航、媒体、配置、历史导出、Agent 接入及错误恢复说明，命令语法表直接取自 AgentCommandCatalog，新增命令也能自动列入。安装／重新安装成功提示只属于本次设置窗口会话，关闭后重开即清除；跨会话完成的旧操作也不能恢复旧成功提示。

本次验证：AgentIntegrationTests 16 项和 FoilCommandsOverviewTests 3 个用例（含中英文参数）通过，覆盖重装反馈清除后安装状态保留、再次操作恢复反馈、当前全部命令出现在本地化帮助及恢复时刷新。已运行 `./run` 并核对 Debug 进程路径；在真实设置页重新安装后看到成功提示，关闭再用 ⌘, 打开后提示消失、状态仍为已安装；点击“命令一览”成功打开更新后的帮助箔，安装位置前缀显示正确。未运行全套测试。


### 12.10 应用与 CLI 的首次通用 Skill 初始化

首次启动应用、设置安装和命令行 `foil install` 共用通用 Skill 默认初始化逻辑。首次启动无需已安装独立 CLI 即可写入通用 Skill（应用自带的 foil 仍可使用）；之后启动和重装保留用户选择。初始化使用进程间锁，遇到未知 Skill 文件保留原文件并允许后续重试；旧设置安装标记保留用户的关闭选择。通用成员注释去掉 Oh My Pi，仍保留该 Agent 的共享目录支持。

验证：接入专项 19 项与帮助专项 3 个用例通过（共 22 个），新增首次应用启动无独立 CLI 安装通用、CLI 自定义目录安装通用、冲突保护与重试、初始化后关闭不被后续启动／安装重置、已有设置选择保留测试。已运行 `./run`，核对 Debug 可执行路径，并验证真实设置页成员注释已去掉 Oh My Pi，已有关闭选择仍被保留。未运行全套测试。


### 12.11 显式重装重新开启通用

修正重装行为：安装或重新安装 foil 工具成功后始终安装并开启通用 Skill，设置与命令行入口一致；普通应用启动仍只初始化一次，不恢复用户关闭的通用。文件冲突保护保持有效。此前重装保留关闭选择的描述由本节替代。

验证：22 个接入与帮助专项用例通过。已运行 `./run`，核对 Debug 进程路径；真实设置中通用原为关闭，点击“重新安装”后变为开启，同时确认 ~/.agents/skills/foofoil/SKILL.md 已写入。


### 12.12 Skill 简单打开快速路径

Skill v3 为已知文件／目录提供 open → wait → 简短确认的快速路径，不预读 guide、不查询无关窗口、不在成功后额外提取目录或总结。未知目标先限定文档范围搜索，找到候选后直接选择或简短确认；文档集合可打开目录，避免建议数百窗口。明确文件自动识别类型、--type 仅用于 stdin、窗口 ID 为位置参数、目录分页上限 20，以及失败时读契约而非猜参数。guide start 同步消除一律先查 capabilities/list/inspect 的引导。

验证：Skill 结构校验通过，20 个接入专项用例通过，含仓库 Skill 与内置安装入口内容一致性检查。已运行 `./run`，重新安装 CLI 并更新全部已管理 Skill；通用和 OpenCode 专用路径均核对为 v3 且字节内容一致，skill check 均为 installed，安装后的 guide 输出也已验证采用快速路径。OpenCode 现有会话需重新加载 Skill 或新建会话；未将静态文件验证称为新会话行为验证。


### 12.13 只读查看默认使用浮箔

Skill v4 的描述与正文增加隐式触发：用户要求打开、查看或预览受支持内容，且未指定应用时优先浮箔；编辑意图、指定其他应用以及 Agent 内部分析读取不触发此默认。支持类型遵循当前 SupportedContent，明确系统预览与后端限制。此次同时在本机 OpenCode 全局 AGENTS.md 写入用户授权的偏好；应用安装器仍只管理 Skill，不自动修改任何 Agent 全局指令。

验证：Skill 结构校验与 20 个接入专项用例通过。运行 `./run` 后重新安装 CLI、更新已管理 Skill；通用和 OpenCode 两份文件与仓库 v4 内容一致，skill check 均为 installed。已核对 OpenCode 全局偏好只写入一份。新会话的实际模型选择仍需后续真实使用验证。


### 12.14 打开后的类型提示

Skill v5 在打开确认后，按已知扩展名、来源类型或 open/wait 已返回的类型附一句可选后续提示。Markdown／EPUB 提示章节或关键词，PDF 提示页码，文本／代码／CSV 提示关键词或适用的行号，图片提示缩放或按需识字，媒体提示指定时间，目录／压缩包提示查找指定文件，网页／其他预览提示置顶参考。不得为生成提示预读正文、目录或媒体信息，不虚构章节标题；用户确认后才查询前置能力并执行。类型未知或用户不需要建议时仅确认。同步本机 OpenCode 偏好，保持无额外调用的打开流程。

验证：Skill 结构校验、20 个接入专项用例通过。已运行 `./run`，重新安装 CLI 并更新已管理 Skill，通用和 OpenCode 实际文件均与仓库 v5 一致，skill check 为 installed。未代替真实 Agent 会话行为验证。
