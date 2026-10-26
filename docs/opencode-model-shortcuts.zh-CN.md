# OpenCode v2 的模型选择快捷键

在 `~/.config/opencode/cli.json` 中设置 `keybinds.model.list` 会替换默认绑定。
若想保留自定义 `ctrl+m` 并恢复默认的 `Ctrl+X`、`m`，使用多绑定：

```json
{
  "keybinds": {
    "model.list": ["ctrl+m", "<leader>m"]
  }
}
```

本仓库提供一次性修复脚本（需要 Python 3）：

```sh
python3 scripts/restore-opencode-model-shortcut.py
```

脚本只修改模型选择绑定，保留其他配置及已有的自定义模型快捷键；原配置备份为同目录的
`cli.json.before-model-shortcut.bak`。重复执行不重复添加绑定。修改后重启 OpenCode。
可用 `--config /path/to/cli.json` 指定另一份 JSON 配置。

`<leader>` 使用 OpenCode 当前配置，默认是 `Ctrl+X`。`Ctrl+M` 与回车在传统终端编码中相同，
该绑定还需要终端与 OpenCode 协商启用键盘消歧协议。未启用时可使用 `Ctrl+X`、`m`。
终端程序自身的键位应在程序配置中修改，浮箔不自动重写第三方配置。

配置格式：[OpenCode v2 CLI schema](https://opencode.ai/v2/cli.json)。
