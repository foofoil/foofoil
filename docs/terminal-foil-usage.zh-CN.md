# 终端箔与通用控制

浮箔仅站外分发，主应用不启用 App Sandbox。macOS 文件与文件夹、摄像头、辅助功能等隐私权限仍由系统管理；无需为开启文件搜索选择主目录，也不应把完全磁盘访问作为普通使用前提。分享扩展及测试 XPC 目标仍保留自己的沙盒。没有旧容器迁移。

## 打开和使用

“文件 → 打开终端…”配置标题、工作目录、Shell、环境变量和多行初始化脚本。打开时优先复用普通空箔，没有空箔时新建；不会替换已有内容或无痕空箔。工作目录可直接输入，也可点击文件夹图标通过系统目录选择器填写。首版支持 zsh/bash 的交互式非登录会话：保留用户 `.zshenv/.zshrc` 或 `.bashrc`，随后在同一 Shell 执行脚本，`cd`、`export`、局部变量和别名不会因另起进程而丢失。首版没有登录 Shell 选项；需要登录配置中的路径时，在用户 rc 或显式环境中配置。

箔信息支持修改标题，并显示初始工作目录、Shell、环境变量和初始化脚本；点击对应铅笔按钮编辑。环境变量和脚本使用多行输入框。配置修改保存后供下一次启动使用，不中断运行中的会话；待启动会话使用修改后的配置。标题可自动折行显示，输入换行会合并为空格。

环境覆盖项和脚本会保存在 SQLite 历史中，不保存继承的完整环境。不要填入口令、token 或私钥。脚本按可信代码对待，不会从终端输出自动生成。新建后直接启动，并在同一 Shell 执行可选脚本；界面不再提供启动方式选择。

关闭后主动从历史重开会载入保存的目录、Shell、环境和脚本，直接建立新会话；运行中的窗口只重新显示，不重复执行脚本。应用启动恢复和崩溃恢复始终停在待启动状态，防止重复执行命令；不恢复旧 Shell/SSH/TUI 内存状态。会话结束（例如 Ctrl+D 退出最后一层，或初始化脚本显式退出 Shell）后直接关闭箔片，不再显示“启动新会话”按钮；需要新会话时从历史重开。

普通终端还保存最近最多 500 行、128 KiB 的普通屏幕纯文本，每五秒至多保存一次，正常关闭和退出也会保存。重开后可点击箭头或“历史会话记录（只读）”标题展开回看，准备内容时显示加载状态。右侧叉号仅隐藏当前窗口中的旧记录，不会删除记录，下次从历史打开仍会显示。右侧关闭按钮旁的垃圾桶按钮经确认后彻底清除之前的会话记录，不可恢复；当前会话及其输出保留。旧记录与新会话分开显示，不向 Shell 重放任何输入或转义序列。记录跨多次会话合并并保持同一上限，不保存全屏 TUI 的备用屏幕。无痕终端不保存这些记录；Shell 自己的命令历史仍由其配置管理。异常终止可能丢失最后几秒输出。

隐藏保留进程。关闭或退出时，检测 PTY 前台组和同一 POSIX session 的进程；活动或不确定时确认。确认终止后依次发送 HUP、等待 0.8 秒、TERM、等待 0.8 秒、KILL，并清理临时启动文件。用 PID 和启动时间核对进程身份；主动通过 setsid 等脱离会话的进程不在管理范围。应用被强制杀死、系统崩溃等场景不能保证完成这套退出清理。

终端聚焦时 Ctrl+A/E/P/N 等控制键交给终端。Command 菜单快捷键保留，复制／粘贴使用 ⌘C/⌘V；字体使用既有内容放大／缩小，透明度使用既有窗口设置。终端内容保留 8pt 内边距，背景圆角与文档箔一致；按住 ⌘ 拖动窗口不会选择文字。文档样式的主题、背景色、文字颜色、字体和字号会实时作用于终端并随历史保存；字体列表与代码箔共用等宽筛选。终端使用字符网格，面板不提供文档式行距和段距；默认 ANSI 调色板采用随背景明暗适配的柔和配色，降低高亮绿和青色的饱和度；程序自行指定的真彩色仍由程序控制。终端视图由会话对象持有，不因 SwiftUI 重绘而重启。

## CLI

使用应用内 `Contents/MacOS/foil`，或执行其 `install` 命令复制到 `~/.local/bin`。终端启动后会将当前 app 的工具目录置于 PATH，并注入只读 `FOOFOIL_TERMINAL_ID`，该值只用于定位会话，不是授权凭证。

```sh
foil list --scope all --json
foil terminal create --title Dev --cwd ~/github/foofoil --command opencode
foil reveal WINDOW_ID
foil hide WINDOW_ID
foil inspect WINDOW_ID --json
foil set WINDOW_ID opacity 0.8
foil close WINDOW_ID --scope all
foil close WINDOW_ID --scope all --force
printf '# Temporary reference\n' | foil open --stdin --type markdown
```

`--env KEY=VALUE` 可重复。`--shell /bin/bash` 或 `/bin/zsh` 选择 Shell。`terminal create` 的 ready 表示已创建运行期窗口和会话对象，不代表初始化或 TUI 已完成；读取 `window.terminal_state`（waiting/running/closing/exited/failed）。通用 `open FILE` 复用普通文件打开管线，返回 accepted，表示已接受装载，未承诺解码完成。首版不支持通用 open 目录。

通用窗口使用 `window.id`，属于当前窗口运行实例；`content_id` 是历史内容身份；`terminal_id` 是会话身份。三者用途不同。窗口关闭或应用重启后，旧窗口 ID 不能定位新实例。

旧命令保持原义：`show FILE` 新建 Agent 只读展示窗口，`update BOARD FILE` 更新，默认 `list/close` 只操作当前凭证拥有的 Agent 窗口。`reveal` 不占用既有 `show FILE`。通用列表和关闭需显式 `--scope all`；新命令 open/reveal/hide/inspect/set/terminal create 本身即通用操作。inspect 仅输出窗口元数据，不输出脚本、环境或终端正文。

透明度接受 0.3–1.0，并沿用窗口现有的 10% 步进取整；响应返回实际生效值。

活动终端的 CLI close 立即返回 CONFIRMATION_REQUIRED，不等待 GUI。调用者在获得终止意图后显式传 --force，才能结束受管理会话。CLI stdout 仅输出 JSON，失败在 stderr 给出稳定错误码且退出非零。

标准输入 Markdown 是临时只读、无痕展示：成功提交后删除 CLI 临时文件，正文只留内存，不承诺历史重开。Markdown 外部资源限制与既有 Agent 展示一致。

## 传输与控制边界

冷启动和 hello 通过既有标准文档事件完成，并按精确 app 路径发现实例。hello 协商 application-control-v1、terminal-v1 和 Unix Socket 能力，返回本次运行端点。CLI 后续优先使用 Unix Domain Socket；旧客户端可继续使用文件事件。新 CLI 对不支持通用能力的旧宿主明确拒绝，不静默改变命令语义。

Socket 位于随机私有临时目录，目录 0700、Socket 0600，双端校验对端 UID。单连接一个请求，4 字节网络序长度 + UTF-8 JSON；请求最多 32 KiB、响应最多 1 MiB、连接最多 16 个、入站绝对截止 5 秒，业务截止 30 秒。正常退出只删除本次创建的端点；崩溃遗留端点不被新运行复用。

两种传输共用原来的凭证、FIFO、revision（仅 Agent 内容更新）、600 秒去重、暂停和撤销。暂停允许授权读取，阻止写入；撤销也阻止通用读取。新建窗口共用每分钟 12 次限额；通用控制最多保留 96 个窗口。所有能力默认只对当前 macOS 用户开放，不提供通用 exec 或现有终端输入注入接口。

超时可能已经提交；600 秒内使用相同 request_id 和相同参数重试，不自动换 ID 或重复创建终端。--caller、终端 ID 与文件路径都不是权限凭证。Developer ID、公证、Gatekeeper 和干净机器验收仍属于正式分发门槛。


## 开发验证记录（2026-10-21）

- 363 项相关回归通过；网页归档测试在独立运行中通过。覆盖历史、文件定位、媒体列表、搜索、字幕、无痕箔与扩展宿主。
- 6 项终端测试通过，包含浅色/深色渲染。原生 PTY 测试覆盖 Shell 初始化状态、后台任务清理、Vim 全屏、中文输出、尺寸变化、历史配置往返、自动恢复不执行脚本，以及 Socket 暂停/撤销/去重。
- 实际开发签名应用验证 zsh/bash、系统 SSH 配置解析（不连接远端）和已安装的 OpenCode `--version`。开发签名验证不能代替 Developer ID、公证或 Gatekeeper 验收。
- 实际 CLI 的 16 项检查全部通过；原生界面验证新建配置、粘贴、Ctrl+A/E/C、活动关闭确认与取消后继续操作。验收脚本见 `scripts/verify-terminal-foil.py`。
- Debug 与 Release 构建、严格签名校验通过：主应用无 App Sandbox，分享扩展及测试 XPC 仍保留沙盒，Hardened Runtime 保留。已执行 `./run` 构建并启动应用。
- 真实远端 SSH、中文输入法组合、多显示器/全屏、干净机器发行与成对 Release 性能对比仍待验收。

本次简化启动流程的回归：36 项终端、Agent 控制和无痕测试通过；补充的终端完整历史入口测试通过；实际 CLI 16 项检查通过。已在应用中验证移除启动方式、周期保存、关闭后从历史自动重开、初始化脚本重新执行，以及展开只读旧记录。
