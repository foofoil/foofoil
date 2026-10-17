# Agent 只读终端

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
