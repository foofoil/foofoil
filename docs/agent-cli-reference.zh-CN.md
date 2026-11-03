# Agent CLI 当前接口（2026-11-03）

随应用交付的 CLI 为 `foofoil.app/Contents/MacOS/foil`。`--help`、`help COMMAND`、`schema [COMMAND]`、`guide [TOPIC]`、`--version` 离线可读，不启动应用或读取凭证。业务输出 JSON，失败退出非零；自然语言指南支持英文和简体中文。schema 版本为 2，宿主仍使用协议 v1 信封，以 `application-control-v2` 协商新增命令。

```sh
foil guide
foil guide reading
foil schema read
foil capabilities
foil list --scope all --limit 20
foil inspect WINDOW
foil open /absolute/reference.pdf --incognito
foil wait --operation OPERATION --timeout 30
foil read WINDOW --page 1 --limit 3000
foil outline WINDOW
foil items WINDOW
foil search WINDOW "关键词" --source rendered
foil navigate WINDOW --page 3 --content-version VERSION
foil media status WINDOW
foil media pause WINDOW
foil config list
foil permissions status
foil settings open --section agent
foil history search "参考资料" --limit 10
foil history open HISTORY_ID --incognito
foil export WINDOW --format original --output /absolute/export
```

窗口、board 与历史身份不同，不按标题猜目标。窗口句柄绑定本次运行，重启旧句柄返回 HANDLE_EXPIRED。inspect 不默认返回正文，包含内容／状态版本、实际阅读位置、只读与无痕、加载错误、窗口 frame 与 screen_id。frame 坐标为指定屏幕可用区域左上角的逻辑点。reveal 显示窗口，focus 显式激活应用。

open 的 accepted 仅表示受理。保留 operation.id，通过 wait 查询完成或失败；wait 超时不取消操作，返回 pending 和 WAIT_TIMEOUT。指定窗口的 wait 查询该窗口最近操作。操作记录最多 128 条，保留 600 秒；pending 最长观察 300 秒。关闭／替换返回 WINDOW_CLOSED／CONTENT_REPLACED。Quick Look 无可靠完成信号时返回 unverified／COMPLETION_UNOBSERVABLE，不能当作 ready。

read 读取当前内存文本；PDF 需指定从 1 开始的 page；rendered 提取当前 WebKit／EPUB 视图；ocr 仅读取已有结果；terminal 仅读取有界保留输出，tail 为 1～2000 行。无文本返回 NO_TEXT，尚未提取返回 TEXT_NOT_EXTRACTED，不支持返回 CAPABILITY_UNAVAILABLE。文本分页按 Unicode scalar，limit 为 1～3000。非零 offset 必须携带上页 content_version，变化返回 STALE_CONTENT。read 不重读外部已修改文件，不隐式 OCR 或递归解包。

outline、items、窗口列表每页最多 20 项，另按实际 JSON 字节限制分页。使用 next_offset 与 content_version 续读；目录版本不含 current／selection。search 返回匹配片段、scalar 偏移与从 1 开始的行号，不改变阅读位置；分页偏移同样绑定版本。navigate／items select／media select 使用返回的不透明 target_id，且必须携带对应版本。PDF 页码、文本行号／比例分别使用当前内容版本／原始文本读取版本。异步导航通过 operation 确认 current／selection。

media 使用现有音频、视频、协商媒体和 Apple Music 控制器；不可用能力明确拒绝，设备交接不被绕过。时间为秒、音量为 0～1。play／pause／seek／音量／静音操作返回 accepted 与 operation；用 wait 和 media status 确认。模式值为 sequential、sequentialLoop、shuffle、singleLoop。没有既有终端输入注入接口。

所有新建来源支持 incognito，历史无痕打开为独立副本，不 touch 原记录。转换复用原服务，收藏拒绝；响应 privacy 报告历史动作与恢复参与状态。重复 setter 为 unchanged。派生箔继承无痕。无痕不清除导出、下载或 Agent 自己的记录。

config 使用固定白名单：search.local-files.enabled、apple-music.library.enabled、search.apple-music.enabled、startup.behavior、document.default-theme、document.default-font-size、history.remove-missing.enabled、media.seek-step、media.controls-auto-hide。list 返回类型、默认值、范围、依赖与立即生效信息；set 不自动开启前置配置。permissions status 不触发系统授权。settings 支持 general、types、keyboardShortcuts、agent。

导出复用当前内容的另存策略和本进程视口捕获。先暂存，再原子提交；默认拒绝覆盖，即使目标在检查后才出现也不会覆盖。显式 --overwrite 才替换。暂不提供压缩包多节点的 CLI 导出，不绕过宿主保存限制。

```sh
foil agent status --json
foil skill install --agent codex
foil skill install --detected
foil skill install --path /absolute/custom/skills/foofoil
foil skill check
foil skill update
foil skill uninstall --agent codex
foil agent setup --agent codex
foil doctor --json
```

agent setup 组合安装 CLI 到 ~/.local/bin 与所选 Skill。install 首次设置时自动安装通用 Skill；uninstall 只移除 CLI。使用 skill install 安装指定 Skill 时必须显式选择 agent、detected 或 path。Codex、Cursor、Pi、OMP、Kimi Code、ZCode 与 Zed Agent 共用 ~/.agents/skills/foofoil；Claude Code 使用 ~/.claude/skills/foofoil。OpenCode v1/v2 使用 ~/.config/opencode/skills/foofoil，WorkBuddy 使用 ~/.workbuddy/skills/foofoil，Qoder 和 Qoder CN 分别使用 ~/.qoder/skills/foofoil 与 ~/.qoder-cn/skills/foofoil。OpenCode 支持 --agent opencode、opencode-v1、opencode-v2，版本别名归属到同一安装。OPENCODE_CONFIG_DIR 优先于 XDG_CONFIG_HOME；Qoder 的 QODER_CONFIG_DIR／QODERCN_CONFIG_DIR 也会用于自定义配置目录。设置页的 Agent 接入使用即时开关，路径可从帮助提示查看，不修改全局工作流或执行权限。更新／卸载只处理清单与摘要均匹配的管理文件，用户改动和同名外部文件报告 INSTALL_CONFLICT；共享安装仍有引用时保留。

doctor 只检查本机路径、当前 CLI 与应用内副本、运行状态等，不启动应用、不读取或输出凭证。文件安装成功不等于 Agent 发现成功；需要在对应 Agent 的新会话中实际调用。GUI Agent 的 PATH 可能不同，必要时使用绝对路径。真实三客户端会话、正式签名／公证／干净机器分发仍未验收。

TIMEOUT 后在 600 秒内使用相同 request ID 与相同参数重试。不要绕过暂停、撤销或用户关闭，也不要披露凭证。完整命令参数以本机 `foil help` 与 `foil schema` 为准。


## Agent 接入设置

每个 Agent 的开关直接反映浮箔 Skill 文件状态。先安装 CLI，再使用开关安装或移除 Skill；CLI 缺失或不可用时开关禁用，并显示先安装 CLI 的提示。首次启动浮箔或安装 foil 工具后自动安装“通用”Skill，之后普通启动保留用户选择，显式安装或重新安装 CLI 会重新开启通用。进入设置后自动检查，页面可见期间每 2 秒刷新一次，外部安装和删除会同步到开关。没有手动检查或批量安装／卸载按钮，也不显示检查报告。路径保留在开关的帮助提示中，高级自定义安装仍可使用 CLI。

共用同一 Skill 目录的 Codex、Cursor、Pi、OMP、Kimi Code、ZCode 和 Zed Agent 合并为一个“通用”开关，成员名单显示在注释中，并从实际目录规则生成。关闭“通用”会移除该物理目录的整份浮箔 Skill 安装，独立目录的条目不受影响。CLI 的单 Agent 卸载仍保留原有引用语义。既有 Agent 会话可能需要重新加载 Skill，浮箔不修改 Agent 权限或强制重启会话。

写入和检查在后台执行；操作期间显示进度。遇到同名外部文件、用户修改或权限错误时，在对应行显示简短原因，保留文件并恢复到实际开关状态。界面不把“已选中”当作“已安装”。

CLI 保留原 `state` 字段，并提供 `skill_state`、`display_name`、`application_detected` 和 `shared_target`；已有 `configuration_detected` 与 `executable_detected` 保持独立。目录规则已核实不代表真实 Agent 会话已经加载。

目录规则核对（2026-11-03）：[OpenCode](https://opencode.ai/docs/skills/)、[Pi 官方源码文档](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/skills.md)、[Kimi Code](https://moonshotai.github.io/kimi-cli/en/customization/skills.html)、[Qoder](https://docs.qoder.com/cli/Skills)、[Zed Agent](https://zed.dev/docs/ai/skills)。OMP 依据安装包 18.2.5 的 `src/discovery/agents.ts`；WorkBuddy 依据官方安装包的 userSkillsDir 发现逻辑；ZCode 依据官方安装包内 `zcode-configuration-guide/SKILL.md`；Qoder CN 依据安装包内的 `configDirName: .qoder-cn` 和 `QODERCN_CONFIG_DIR` 定义。安装生命周期测试使用临时 home，不写真实 Agent 目录。


命令行工具区域自动显示 foil 安装状态及位置。未安装时提供“安装 CLI 命令”，已安装时提供“重新安装”；检查当前应用环境的 PATH，找不到已安装副本或被其他同名命令遮蔽时给出简短提示。GUI 的 PATH 不代表所有终端的环境。安装使用 ~/.local/bin/foil；明确识别为当前浮箔二进制的外部副本也可识别。重新安装仅覆盖已管理副本，或用户显式重装且内容与当前应用内二进制完全相同的副本，不覆盖未知同名程序。首次设置标记保存在应用支持目录，普通启动不重置已关闭的“通用”，显式安装或重装 CLI 会重新开启。


设置的 foil 注释提供“命令一览”链接，点击打开帮助箔；路径明确标注“命令安装位置”。帮助箔的中英文语法表与 CLI 共用命令定义。安装／重新安装成功提示只在当前设置窗口会话显示，关闭后重新打开清除，实际安装检测状态保留。

通用成员注释不再列出 Oh My Pi，但其共享目录支持保留。默认初始化仅执行一次；后续普通启动不重置已关闭的选择，安装或重装 CLI 会重新开启通用。
