# 终端键盘消歧

终端箔支持 [Kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/)
的按键消歧能力（flag 1）。程序通过 `CSI ? u` 查询、`CSI > flags u` 入栈、
`CSI < count u` 出栈，或 `CSI = flags ; mode u` 更新模式。
查询只返回实际支持的位，不宣称支持按键释放、全键转义、替代键或关联文本增强。

未协商时保留 SwiftTerm 的传统输入编码。启用后，`Ctrl+M` 发出 `CSI 109;5u`，
回车仍为 `0x0D`；`Ctrl+I` 与 Tab 同理。Esc、Control 组合键及功能键使用消歧编码。
普通文字继续经过原有输入法通道；Option 是否作为 Meta 沿用 SwiftTerm 的设置。
Command 菜单及窗口布局快捷键仍优先处理，不转成终端协议事件。

主屏和备用屏各自保存至多 32 层模式。正常出栈、返回主屏或终端重置后恢复相应模式；
进程结束会清空协议状态。程序若在主屏启用协议后崩溃且没有恢复模式，可能仍需在 Shell
输入 `reset`，因此无修饰的回车、Tab、Backspace 保留传统字节。

协商解析位于 PTY 输出进入 SwiftTerm 之前，保留跨分片状态。普通 ANSI 序列原样交给
SwiftTerm；OSC、DCS、APC 等字符串内的内容不作为键盘协商执行。响应与设备属性查询
保持输出顺序。该实现不修改 SwiftTerm 依赖，也不通过改写第三方配置模拟键盘协议。

## 验证

定向测试：

```sh
xcodebuild test -project foofoil.xcodeproj -scheme foofoil \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build \
  -only-testing:foofoilTests/TerminalKeyboardProtocolTests \
  '-only-testing:foofoilTests/TerminalFoilTests/negotiatedControlKeysReachPTYAndRestoreLegacyInput(enhanced:)'
```

协议测试覆盖协商、分片、模式栈、主／备用屏切换、控制字符串透传、异常输入和功能键。
真实 PTY 测试同时覆盖传统和增强编码，以及恢复后的输入。

人工验收：在终端箔启动 OpenCode v2，配置模型选择为 `ctrl+m` 和 `<leader>m`，
确认两个快捷键均打开模型列表，Esc 能关闭；确认 `<leader>l` 仍打开会话列表。
退出后检查 Shell 的回车、Tab、Ctrl+C、Ctrl+D，以及窗口布局快捷键。
