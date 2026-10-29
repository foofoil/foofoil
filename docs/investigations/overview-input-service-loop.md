# 总览输入服务重建循环（2026-10-28）

## 已确认根因

总览每个控制器只创建一个 `NSTextField`。反复创建的是系统输入服务的远程视图，触发链为：

1. `FoilExposeViewController.synchronize()` 在无搜索范围时，先设置非空 `placeholderString`，随后又设为 `""`。
2. AppKit 的 `NSTextFieldCell.setPlaceholderString` 调用 `NSCell._restartEditingWithTextView`，结束并重启共享 field editor。
3. `controlTextDidEndEditing` 调用 `model.requestSearchFieldFocus()`，发布模型更新。
4. 下一轮 `scheduleUpdate` 再执行 `synchronize`，再次改写占位文字并结束编辑。没有键入内容也会持续循环。
5. 编辑会话不停激活/停用输入上下文，反复创建 `CursorUIViewService` 远程视图。服务进入异常后可以在浮箔退出后继续繁忙；终止服务可恢复响应，但不修复宿主触发源。

本机 macOS 27.0.1 (26A434) 的隔离探针直接链接当时的 `foofoil.debug.dylib`，创建实际 `FoilExposeController.makePanel`，使用空数据及禁用的文件/音乐搜索，未加载用户历史，也未启动终端。进程有外部超时，避免依赖已被更新循环挤占的主线程定时器退出。旧版探针短时运行可复现重建风暴；另一个只含普通 NSTextField、相同窗口层级的最小探针不复现。

旧版主线程 sample 直接包含以下链路，故结论不再只基于相关性或服务名称：

```text
FoilExposeViewController.scheduleUpdate → synchronize
  NSTextField.setPlaceholderString → NSTextFieldCell.setPlaceholderString
    NSCell._restartEditingWithTextView → NSCell.endEditing
      NSWindow.endEditingFor → NSTextView.resignFirstResponder
        NSTextField.textDidEndEditing
```

同一 sample 也包含输入上下文 deactivate 和 `TUINSCursorUIController.activate` / `TUINSWindow.setRemoteViewController`。

## 修复

- 占位文字先计算最终值，无范围时直接取空字符串；仅在值改变时设置，防止重启编辑会话。
- 聚焦及编辑结束后的焦点恢复，仅允许可见、处于 key 状态、没有 attached sheet、未开始关闭的总览。
- 关闭前先停止视图订阅与焦点恢复，再结束搜索框编辑；排队的更新也检查关闭标记。
- 不禁用系统文本光标，不使用私有 API，不更改输入法、窗口层级或签名配置。

## 验证与边界

- 旧版隔离探针的日志查询窗口 14:57:26–14:57:30 中有 113 条远程视图创建记录。新版同一探针运行两秒只有 1 条；10 次定时观测中焦点请求保持 1、服务窗口保持 6。系统全局窗口计数可能包含其他客户；未将其解释为浮箔独占的窗口数。
- `refreshingOverviewKeepsSearchEditingSessionAndSelection`：连续 20 次模型/视图刷新后，编辑器、第一响应者和选区保留，焦点请求不增长；切换到历史范围后再次刷新也稳定。
- `hiddenAndDismissingOverviewDoesNotRestoreSearchFocus`：隐藏窗口、关闭过程中的编辑结束回调及排队更新不会重新激活搜索框。
- 定向运行 `FoilExposeViewTests`、`FoilExposeModelTests`、`FoilExposeShortcutTests`：75 项，74 通过、1 失败。结果包为 `build/Logs/Test/Test-foofoil-2026.10.28_14-59-12-+0800.xcresult`，未跑全套。
- 失败项 `historyCategoryFiltersOnlyHistoryAndKeepsCountsStable` 最后的 `!model.showsHistorySection` 断言仍按 `resultFilter = .files` 判断。现有 `overview-search` 提交 `a1597266f51c` 已将该属性改为由 `activeScope` 决定，旧断言未同步。此次未修改该属性、旧测试或其他分支的改动。
- 编译有现存的 WindowConfig Sendable 及无 AppIntents 依赖提示；结果包还记录了现有信息面板/范围菜单布局约束和输入服务 QoS 的运行时提示。本次没有将这些提示描述为已修复。
- `./run` 成功构建、嵌入模块并启动 Debug 版。通过原生 UI 验证空搜索打开总览、`/` 范围菜单、选择历史、输入查询以及 Esc 关闭；搜索框保持焦点，观察期间服务 CPU 很低，没有持续重建风暴。
- 后续空搜索总览静置观察中，AX 确认焦点仍在 `expose.search`。15:13:55 快照：CursorUIViewService CPU 0%、RSS 约 19 MiB、窗口数 6，WindowServer CPU 28.2%；15:06:28 至 15:13:55 的查询范围仅新增 1 条远程视图创建记录，没有持续增长。验证结束已收起总览，修复版保留运行。
- 这是对已复现总览循环的修复，不是所有历史 WindowServer 异常的归因，也不是长时压力验证。实际鼠须管候选交互和其他文本路径未在此轮全面验证。

## 本机证据

`~/Library/Logs/foofoil-cursor-ui/overview-fix-20261028/` 保存原版 sample、创建日志、探针源码及修复版窗口/进程快照。

`~/Library/Logs/foofoil-cursor-ui/incident-overview-20261028/` 保存用户退出浮箔后服务仍繁忙时的 sample。服务线程池达到 64 上限，主线程处于 Core Animation 清理及锁等待路径；先 TERM 后 KILL 恢复系统响应。这不意味着每次总览循环都必然产生相同服务端栈。

## 引入提交追溯

直接引入已复现循环的是 **`1ef99b8e3f216855a2a839bf38885f303cfb7728`**，提交时间 **2026-10-27 10:17:24 +08:00**，标题 `feat: refine quick open menus and blank foil controls`。

该提交增加 `QuickOpenSearchPrompt` 覆盖层，为了让出原生占位文字的位置，在原有占位文字赋值之后新增：

```swift
if model.activeScope == nil { searchField.placeholderString = "" }
```

因此无范围的每次刷新都由提示语变成空串，下一轮又由空串变回提示语。原来的“编辑结束后恢复焦点”机制早已存在：初始 AppKit 总览提交 `75ba0f9c`（10 月 23 日 14:35:57）已包含，`75bfd8f1`（同日 20:48:16）增加剪贴板焦点条件。这些是背景条件；本次确认的新增触发点是 `1ef99b8e` 的占位文字清空。

为避免只凭 blame 归因，提取 `1ef99b8e^` 和 `1ef99b8e` 的完整历史视图文件，在相同的当前模型/网格依赖、空数据、相同面板配置下编译隔离探针。每个进程均有 2.5 秒外部截止，不在当前工作区回退或改写历史。结果如下：

|历史视图变体|远程视图创建日志|主循环观测|
|---|---:|---|
|提交前（父提交）|1|定时器正常执行，焦点请求保持 1|
|提交后|23|未执行到定时器输出，主队列持续处理刷新|
|提交后，仅删除新增的清空行|1|定时器正常执行，焦点请求保持 1|

这将触发边界进一步收窄到该提交新增的一行。它是对历史视图代码的受控对照，不是两个完整历史 App 及其历史依赖的构建二分，也不将所有过去的系统异常归于这一提交。

源码和输出在本机证据目录的 `history-before.swift`、`history-after.swift`、`history-after-without-clear.swift`、`history-*-run.txt` 和 `historical-ab-creations.txt`。对照完成后服务 CPU 为 0%，修复版浮箔仍在运行。


## 2026-10-29 旧安装版被验证工具误启动

本次用户报告高 CPU 时，CursorUIViewService（PID 23386）占用约 83–96% CPU，sample 再次记录 64 个 dispatch 线程达到上限，主线程停在 CAContext 清理与 Core Animation 锁等待。当前 Debug 应用（PID 75909）的 sample 则主要处于事件等待，没有捕获到上次的占位文字/编辑器重启循环。

按客户端 PID 汇总统一日志后，16:18–16:19 的 `com.apple.TextInputUI.xpc.CursorUIViewService.peer` 连接激活记录分别为：

- `/Applications/foofoil.app`（PID 75959）：2,693 + 1,816 = 4,509 次。
- 当前工作区 Debug 应用（PID 75909）：1 + 7 = 8 次。

旧安装版可执行文件的修改时间为 2026-10-28 14:21:28，早于上文 14:59 的修复验证。上一轮验证通过应用名称调用原生 UI 工具，意外启动这份旧安装版，并打开其总览；之后虽然停止了旧应用，服务端仍维持异常状态。因此这次日志直接定位到误启动的旧进程，不能将它归为当前焦点补交改动已复现的重建循环。上一轮只在切到 Debug 版后验证交互、没有继续检查服务 CPU，是验证遗漏。

保留 sample 和日志后，对异常服务先 TERM；未退出，再 KILL，使系统按需重启服务。仅使用 Debug 应用的绝对路径打开总览。恢复后的 16:24:56–16:25:56，每 5 秒采样一次，13 次观测的服务 CPU 均为 0%，RSS 从约 26 MB 稳定到约 19 MB；16:24:40 起的恢复日志查询只发现 Debug 客户端 1 次服务连接。此为短时进程观察；结束时 UI 已回到空箔，不能将整段都算作总览静置，也不能代替所有输入法与长时交互的验证。

`AGENTS.md` 已补充原生 UI 验证必须指定工作区 Debug 应用绝对路径、核对进程路径，禁止通过显示名称或 bundle ID 定位，以免 LaunchServices 打开旧安装版。

本机证据：`~/Library/Logs/foofoil-cursor-ui/incident-old-installed-overview-20261029/`，含应用/服务 sample、事发前 15 分钟日志、恢复日志和定时 CPU/RSS 观测。
