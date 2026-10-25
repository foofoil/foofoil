# foil 终端命令一览

`foil` 是随浮箔交付的本地命令行工具，用于打开文件、管理箔片和创建交互式终端。终端箔内可直接调用；其他终端可先安装到默认的 `~/.local/bin`：

```sh
/Applications/foofoil.app/Contents/MacOS/foil install
~/.local/bin/foil --help
```

应用不在“应用程序”目录时替换上述路径。若命令未找到，将 `~/.local/bin` 加入 PATH，或使用完整路径。升级应用后可再次安装；不会覆盖第三方同名命令。

## 打开与窗口控制

| 命令 | 用法 |
| --- | --- |
| `foil open FILE` | 通过普通文件打开流程打开文件；返回 accepted 不代表装载完成，不支持目录 |
| `foil open --stdin --type markdown` | 从标准输入展示只读无痕 Markdown |
| `foil list --scope all` | 列出全部可控制窗口，取得 `windows[].id` |
| `foil reveal ID` | 显示窗口 |
| `foil hide ID` | 隐藏窗口，终端任务继续运行 |
| `foil inspect ID` | 查询类型、可见性、透明度及终端状态等元数据，不读取终端正文 |
| `foil set ID opacity VALUE` | 设置透明度，支持 0.3–1.0，按窗口现有的 10% 步进取整，以响应为准 |
| `foil close ID --scope all` | 关闭指定窗口；活动终端返回 CONFIRMATION_REQUIRED |
| `foil close ID --scope all --force` | 明确终止受管理的活动终端任务并关闭窗口 |

```sh
foil open "$HOME/Documents/参考.md"
foil list --scope all --json
foil inspect WINDOW_ID
foil set WINDOW_ID opacity 0.8
foil hide WINDOW_ID
foil reveal WINDOW_ID
printf '# 临时参考\n\n正文\n' | foil open --stdin --type markdown
```

用实际返回的 ID 替换示例中的 `WINDOW_ID`。窗口 ID 只在当前应用运行期有效，关闭或重启后失效；`content_id` 是历史内容身份，`terminal_id` 是会话身份，不能混用。

## 创建交互式终端

```sh
foil terminal create --title Dev --cwd "$HOME/projects" --shell /bin/zsh
foil terminal create --title Build --cwd /path/to/project --command 'pwd; swift build' --env MODE=debug
foil terminal create --incognito --shell /bin/bash
```

支持 `/bin/zsh` 和 `/bin/bash`。`--cwd DIR` 设置工作目录，`--command SCRIPT` 在同一个 Shell 执行可信初始化脚本；`--env KEY=VALUE` 可重复传入，`--title TITLE` 设置标题，`--incognito` 创建无痕终端。配置和初始化脚本会保存到普通历史，不要写入口令。ready 表示会话对象已建立，不代表脚本完成；可用 inspect 查看状态。

## Agent 只读展示

| 命令 | 用法 |
| --- | --- |
| `foil show FILE [--title TITLE] [--incognito]` | 新建只读展示箔 |
| `foil update BOARD FILE [--expected-revision N]` | 更新已有 Agent 箔，保留布局与隐藏状态 |
| `foil list` | 只列出当前凭证拥有的 Agent 箔 |
| `foil close BOARD [--expected-revision N]` | 只关闭当前凭证拥有的 Agent 箔 |

支持本地 UTF-8 文本、代码、Markdown、光栅图片首帧与 SVG；不支持 PDF、HTML、网址、媒体、目录或压缩包。调用方保留原文件，文件变更后显式 update。Markdown 不加载关联图片，图片可单独 show。普通箔进入历史；无痕箔不进入历史或重启恢复。show 总是新建，不要把 update 失败改为重复 show。

```sh
foil show ./report.md --title '报告' --json
foil update BOARD_ID ./report.md --expected-revision 1
foil close BOARD_ID
```

## 通用选项与安装

| 选项或命令 | 说明 |
| --- | --- |
| `--json` | 响应格式选项；当前成功响应本来就输出 JSON，失败退出非零并在 stderr 输出错误码 |
| `--request-id ID` | 请求去重标识；超时可能已执行，600 秒内用相同 ID 和相同参数重试 |
| `--caller NAME` | 显示调用方名称，不是授权凭证 |
| `--session FILE` | 使用独立会话凭证文件；也可设置 `FOIL_SESSION` |
| `--app APP` | 指定应用路径；也可设置 `FOIL_APP` |
| `foil install [--directory DIR]` | 安装 CLI，默认 `~/.local/bin` |
| `foil uninstall [--directory DIR]` | 移除安装的 CLI 及收据，不删除应用或文档 |
| `foil --help` / `foil help` | 查看命令摘要 |
| `foil --version` | 查看协议版本 |

默认凭证位于 `~/.local/state/foofoil/session.json`，不要分享该文件。通用设置可暂停 Agent 控制或撤销会话。路径含空格时使用引号。命令只控制本机浮箔，不提供向已有终端注入输入的接口。
