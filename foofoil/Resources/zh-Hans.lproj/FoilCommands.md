# foil 终端命令一览

`foil` 是浮箔自带的本机命令行工具，可打开和展示内容、读取导航、控制窗口与媒体、创建终端，以及查询配置、历史和 Agent 接入。下方语法取自当前 CLI，具体能力以 `foil capabilities WINDOW` 为准。

## 安装与起步

设置 → Agent 接入中的“命令行工具”会自动检测安装状态，可安装或重新安装到 `~/.local/bin/foil`。首次启动浮箔时自动安装“通用”Skill。安装或重新安装 foil 工具也会安装并开启“通用”；普通启动保留已有开关选择。CLI 不可用时 Agent 开关禁用。命令也可以手动安装：

```sh
/Applications/foofoil.app/Contents/MacOS/foil install
~/.local/bin/foil guide
~/.local/bin/foil --help
```

应用位于其他位置时替换上述应用路径。若 PATH 找不到命令，可使用完整路径。安装不会覆盖未知的第三方同名文件。终端箔内已提供 `foil` 的 PATH。

| 离线说明 | 内容 |
| --- | --- |
| `foil --help` / `foil help` | 命令摘要 |
| `foil help COMMAND` | 某条命令的语法，例如 `foil help media seek` |
| `foil guide [TOPIC]` | 起步与按主题展开的工作流 |
| `foil schema [COMMAND]` | JSON 契约、参数和范围；静态契约不代表某个窗口的运行时能力 |
| `foil --version` | CLI、入口、协议与应用构建版本 |

这些说明入口不启动应用、不要求凭证。语法中的 `[]` 表示可选项，`|` 表示备选值或互斥入口；请替换 FILE、WINDOW、BOARD、VERSION 等占位符。

{{command_tables}}

## 打开、等待与读取示例

```sh
foil open "$HOME/Documents/参考.pdf" --incognito
foil wait --operation OPERATION_ID --timeout 30
foil capabilities WINDOW_ID
foil inspect WINDOW_ID
foil read WINDOW_ID --page 1 --limit 3000
foil read WINDOW_ID --page 1 --offset 3000 --limit 3000 --content-version VERSION
foil outline WINDOW_ID
foil navigate WINDOW_ID --target TARGET_ID --content-version VERSION
foil media status MEDIA_WINDOW_ID
foil media pause MEDIA_WINDOW_ID
```

示例中的 ID 和版本取自前一步响应。`open` 的 accepted 仅表示受理，保存 `operation.id` 并用 `wait` 确认完成。超时不会取消操作；Quick Look 无可靠完成信号时返回 COMPLETION_UNOBSERVABLE，不冒充成功。`is_loading: false` 不代表所有异步操作已完成。

窗口 ID 只在本次应用运行期有效；BOARD 是所属 Agent 展示身份，`content_id` 是内容身份，`terminal_id` 是终端会话身份，不能混用。`list` 默认只列当前凭证所属展示箔；查询或关闭普通窗口须用 `--scope all`。

正文来自当前已加载内容。PDF 指定从 1 开始的页码；`rendered` 读取当前网页／EPUB 等视图的可提取文本；`ocr` 仅读已有结果；`terminal` 仅读有界保留输出，`--tail` 为 1～2000 行。非零 offset 必须带上一页的 content_version。文本偏移使用 Unicode scalar，每页最多 3000；目录、项目和窗口列表每页最多 20 项，并另按响应字节限制分页。使用 next_offset 和对应版本续读，STALE_CONTENT 时重新查询。读取不隐式 OCR、递归解包或重读外部已修改文件。

search 返回片段、偏移与行号，不移动阅读位置。导航必须携带版本且只选一种定位；异步操作使用 wait 与 inspect 确认实际结果。媒体时间单位为秒，音量为 0～1，不支持的后端操作会明确拒绝。窗口 frame 使用指定屏幕可用区左上角为原点的逻辑点，返回钳制后的实际坐标。

## 展示、终端与无痕

```sh
foil show ./report.md --title '报告' --incognito
foil update BOARD_ID ./report.md --expected-revision 1
printf '# 临时参考\n\n正文\n' | foil open --stdin --type markdown
foil terminal create --title Dev --cwd "$HOME/projects" --shell /bin/zsh
foil terminal create --title Build --cwd /path/to/project --command 'pwd; swift build' --env MODE=debug
```

show／update 用于只读 Agent 展示，支持本地 UTF-8 文本、代码、Markdown、光栅图片首帧和 SVG；普通 open 还可打开宿主支持的文档、媒体、目录、压缩包、URL 和剪贴板。展示源文件须由调用方保留，变更后显式 update；Markdown 外部图片会被阻止。show 总是新建，不要用它绕过用户关闭或覆盖失败的更新。

终端支持 `/bin/zsh` 与 `/bin/bash`。创建时立即执行可选 startup script，普通历史会保存配置与环境，不要写入口令。ready 不代表脚本已经执行完成；已有终端不提供输入注入接口。关闭活动终端可能要求 CONFIRMATION_REQUIRED，只有获准终止时才使用 `--force`。

open 的各种来源、show、terminal create 和 history open 均支持 `--incognito`。无痕不进入历史或重启恢复；无痕历史打开是独立副本，不更新原记录。收藏历史拒绝转换，重复设置目标状态保持幂等。无痕不会删除导出、下载或 Agent 自己的记录。

## 配置、导出与接入

config 只开放白名单，list 返回类型、默认值、范围与依赖；set 不自动开启前置条件。permissions status 只查询，不发起系统授权。历史搜索返回有界元数据；导出复用宿主保存限制，要求绝对输出路径，默认不覆盖，只有显式 `--overwrite` 才替换。暂不提供压缩包多节点的 CLI 导出。

设置中的开关即时安装／移除对应 Skill 并自动检查。“通用”包含 Codex、Cursor、Pi、OMP、Kimi Code、ZCode、Zed Agent 等共用目录的 Agent；其他目录单独管理。已有 Agent 会话可能需要重新加载 Skill。CLI 的 skill／agent 管理命令仍可用于指定目标或高级自定义路径；文件写入成功不代表 Agent 会话已经发现。

## 通用选项与错误恢复

| 选项 | 说明 |
| --- | --- |
| `--json` | 业务响应默认已是 JSON，失败退出非零并在 stderr 输出错误码 |
| `--request-id ID` | 请求去重标识；TIMEOUT 可能已执行，600 秒内用相同 ID 和相同参数重试 |
| `--caller NAME` | 调用方显示名称，不是授权凭证 |
| `--session FILE` | 独立凭证文件，也可使用 FOIL_SESSION |
| `--app APP` | 指定应用路径，也可使用 FOIL_APP |

默认凭证是 `~/.local/state/foofoil/session.json`，不要分享。设置可暂停 Agent 控制或撤销会话。遇到版本冲突、用户关闭、暂停或撤销时重新确认状态，不要盲目重建。路径含空格时使用引号。进一步排错使用 `foil doctor --json` 或 `foil guide troubleshooting`。
