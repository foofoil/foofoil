# Agent 只读终端

> 2026-11-03：新增 Agent CLI 与接入管理，请先看 [当前 CLI 契约与工作流](agent-cli-reference.zh-CN.md)。下文的旧阶段限制只适用于其原始实现，不代表新增 open/read/media 等入口。


> 2026-10-20 更新：主应用已取消沙盒；旧 Agent 命令保持作用域，新增通用窗口控制与交互式终端。当前行为以 [终端箔与通用控制](terminal-foil-usage.zh-CN.md) 为准。下文中的沙盒实验为历史记录。

随应用交付的原生命令位于 `foofoil.app/Contents/MacOS/foil`。本机开发功能已接入；Developer ID、公证和干净机器分发验证尚未完成。

安装至默认 `~/.local/bin`（应用安装在其他位置时替换路径）：

```sh
/Applications/foofoil.app/Contents/MacOS/foil install
~/.local/bin/foil --version
```

若 shell 尚未搜索 `~/.local/bin`，使用上面的绝对路径，或自行将目录加入 PATH。安装不会覆盖第三方同名命令。应用升级后从新 app 再运行 install；移动应用后安装副本通过系统应用登记发现它。`foil uninstall` 删除工具及安装收据，不删除应用或文档。

```sh
foil show ./architecture.svg --title '系统架构' --caller 'My Agent' --request-id diagram-1 --json
foil show ./report.md --incognito --request-id report-1 --json
foil update BOARD_ID ./report.md --expected-revision 1 --request-id report-2 --json
foil list --json
foil close BOARD_ID --json
```

show 总是新建，update 保留窗口布局和隐藏状态。原文件由调用方保管，成功不表示已经归档；同路径覆盖后须显式 update。普通窗口保存引用并进入历史，无痕窗口不进历史或恢复。重启后普通窗口恢复为人工窗口，旧控制 ID 失效。

支持 UTF-8 文本／代码／Markdown、PNG/JPEG/HEIC/TIFF/GIF/WebP/BMP 和 SVG。光栅图片展示首帧。Markdown 不加载关联图片，显示不可用提示并返回 `MARKDOWN_RESOURCES_BLOCKED`；需要图像时单独打开图片或 SVG。接口不接受正文直传、编辑、写回文件、PDF、HTML、网页、媒体、目录或压缩包。

stdout 为 JSON，失败退出非零并在 stderr 给出错误码。保存 board_id 和 revision；TIMEOUT 不代表未执行，600 秒内使用相同 request_id 及相同参数重试。期限外不得盲目重建窗口。BOARD_NOT_FOUND、CONTROL_PAUSED 和 PERMISSION_DENIED 不应改用 show 或新凭证绕过。

通用设置提供“暂停 Agent 控制”和“撤销 Agent 会话”；暂停允许授权查询，阻止新写入与在途提交。来源显示在箔片信息中。GUI 替换内容会解除控制，移动、缩放和置顶不会。暂停、授权及撤销作用于本次运行；退出应用后不恢复控制身份。

默认 CLI 调用共享私有凭证 `~/.local/state/foofoil/session.json`。不同调用方用 `--session FILE` 分离；`--caller` 只是显示名称。不要输出或分享凭证。开发时可用 `--app /absolute/foofoil.app` 指定构建，或设置 FOIL_APP；FOIL_SESSION 对应凭证文件选项。

应用内的 `foofoil.app/Contents/Resources/AgentSkills/foofoil/SKILL.md`（[源码](../skills/foofoil/SKILL.md)）可复制到支持该格式的 Agent 技能目录；本项目仅验证原生 CLI，不承诺其他 Agent 的安装兼容性。完整限额、就绪语义及分发待验证项见 [协议](agent-terminal-protocol-v1.zh-CN.md)。

普通文件可通过 `foil open FILE --incognito` 无痕打开。返回的窗口快照包含 `incognito`；`accepted` 仅表示已受理，不表示加载完成。`foil set ID opacity VALUE` 的有效范围为 0.3～1。

`foil guide [presentation|windows|terminal|privacy]` 和 `foil schema [COMMAND]` 可离线查看现有操作；`foil capabilities [WINDOW_ID]` 查询当前应用或窗口开放的能力。`foil set WINDOW_ID incognito true|false` 设置无痕目标状态，收藏的历史箔转无痕时返回 `HISTORY_FAVORITED`。

窗口置顶和边框可分别用 `foil set WINDOW_ID pinned true|false` 和 `foil set WINDOW_ID border true|false` 设置；窗口快照返回 `pinned` 和 `border`。

`foil read WINDOW_ID --source original --offset 0 --limit 3000` 读取当前内存中的文本或 Markdown 正文，偏移和长度以 Unicode scalar 计。续读使用返回的 `next_offset` 和 `content_version`；内容改变时返回 `STALE_CONTENT`。其他类型不支持此入口。

应用级能力列出 `content.read.original`；窗口级查询仅在当前文本可读取时列出它。非零偏移必须带 `--content-version`。

`foil set WINDOW_ID title TITLE` 设置窗口自定义标题；空标题恢复自动标题。

窗口快照包含采样时间 `observed_at` 和当前 `is_loading` 标记；`is_loading: false` 不证明异步打开已成功或页面渲染完成。

`foil outline WINDOW_ID` 分页查询现有大纲导航节点。使用返回的 `next_offset` 和 `content_version` 续读；目录变化后返回 `STALE_CONTENT`。使用返回的 `target_id` 和 `content_version` 执行 `foil navigate WINDOW_ID --target TARGET_ID --content-version VERSION`。跳转返回 `accepted`，不表示异步滚动已完成。
