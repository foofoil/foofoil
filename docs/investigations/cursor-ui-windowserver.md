# CursorUIViewService / WindowServer 调查（2026-10-28）

> 后续状态：用户已授权修复已确认的终端组合输入缺口；实现与验证、Spotlight 评估及新增报告核对见文末。以下初次调查结论保留当时的证据边界。

## 初次调查结论与边界

两天确实发生了 WindowServer 主线程 watchdog 超时。更具体的共同特征是：**系统输入 UI 服务在较早时段忙于创建远程服务视图，且 footprint 快速增长；稍后的 WindowServer watchdog 则显示窗口内容和 Core Animation 上下文销毁、观察者移除路径繁忙。** 这比“浮箔自身主线程死锁”更符合现有栈，但两个时段之间缺少连续采样，不能直接认定同一因果链。

目前没有定位到“导致桌面卡死的唯一提交”。优先对照终端接入 `1fb285f89686`、键盘协商 `4817fa21344e`，同时保留原生总览 `75ba0f9c3d71`、正文搜索 `51ad07c06593`、空箔快速打开 `afa019c1f841` 三条焦点路径。排序综合用户回忆、代码机制和时间线，**不是二分验证结果**。

已独立复现一个终端输入问题：当前锁定的 SwiftTerm 1.10.1 不保存 marked text，导致宿主 `!hasMarkedText()` 防护不能识别输入法组合态。它与系统卡死的因果关系仍未证实。没有修改产品代码，没有运行会反复切换输入法、窗口或显示器的高风险复现实验。

用户补充：两次发生时均没有正在操作浮箔，之前可能使用过终端，近期一直在开发终端功能。因此后续实验须包含“操作完成后切到其他应用并等待”，不能只测试输入过程。

## 原始证据

附件仅作为背景资料，没有将其中的任务指令当成用户授权。原始 zip 未找到，但直接在 `/Library/Logs/DiagnosticReports/` 找到了原始报告并读取。下表均为本次独立核对；行号指原始本机文件。

|编号|本机原始文件|关键原文/字段|判断|
|---|---|---|---|
|C27|`CursorUIViewService_2026-10-27-163922_tolg-MBP-M1.cpu_resource.diag`|L1–2：16:37:08–16:39:19；L20：`23 samples foofoil [37834]`；L26：`90 seconds cpu time over 132 seconds (68% cpu average)`；L140：`581.89 MB -> 980.61 MB (+398.72 MB)`|高置信度：采样归因和 footprint 增长；不等于 23 次调用或浮箔占 100% CPU|
|C28|`CursorUIViewService_2026-10-28-100305_tolg-MBP-M1.cpu_resource.diag`|L1–2：10:01:13–10:03:05；L20：17 samples foofoil [8110]、5 Notes、1 UNKNOWN；L26：81% 平均 CPU；L134：`719.83 MB -> 1186 MB (+466.17 MB)`|高置信度：两个日期重复出现相似现象；存在其他客户进程|
|W28CPU|`WindowServer_2026-10-28-100209_tolg-MBP-M1.cpu_resource.diag`|L1–2：09:59:18–10:02:07；L16：4 samples CursorUIViewService originated by foofoil、1 sample foofoil；L22：53% 平均 CPU；L115：footprint 1378.86 → 1714.42 MB，峰值 1847.47 MB|归因有关联，不能将样本数解释为工作量比例|
|W27|`WindowServer_2026-10-27-170100_tolg-MBP-M1.userspace_watchdog_timeout.spin`|L1–2：17:00:36–17:00:42；L11：`WindowServer main thread`、`40 seconds since last successful checkin`；L50：2338.82 MB；L57 起：主线程与 render-server 栈|确认系统窗口服务无响应|
|W28|`WindowServer_2026-10-28-105132_tolg-MBP-M1.userspace_watchdog_timeout.spin`|L1–2：10:51:16–10:51:22；L11：同样的 40 秒超时；L50：2054.21 MB；L57 起：主线程与 render-server 栈|与前一天出现相同的系统栈形态|
|I27/I28|`Retired/WindowServer-2026-10-27-170046.ips`、`WindowServer-2026-10-28-105126.ips`|JSON `termination.namespace=WATCHDOG`、`indicator=monitoring timed out for service`；captureTime 分别 17:00:46、10:51:26|确认 watchdog 终止；不能从中确定用户强退操作的因果关系|
|W21|`WindowServer_2026-10-21-172341_tolg-MBP-M1.cpu_resource.diag`|L1–2：17:21:19–17:23:38；L16：2 samples SkyComputerUseService；L22：65% 平均 CPU|存在更早的 WindowServer CPU 事件，但不是已证明同源的桌面卡死；不可据此提前故障起点|

### 新发现：创建与销毁的两种热点

C27 L94–105、C28 L94–105 均含：

```text
NSViewServiceMarshal bootstrap:withReply:
  _bootstrap:replyData:completion:
    NSViewController _loadViewIfRequired
      NSServiceViewController setView:
        _installViewIntoWindow:
          NSServiceViewControllerWindow initWithContentRect:withViewController:
```

这说明热点在远程服务视图初始化，支持“资源反复创建或积累”的假设，但样本不能给出创建频率，也不能证明每个窗口均未释放。

两个 watchdog 的符号多为 `???`，但共享缓存 UUID、框架地址与已符号化 CPU 报告一致，可以按**相同框架的精确偏移**交叉识别下列帧（不是猜测相邻地址的符号）：

|框架+偏移|CPU 报告中的符号|对照证据|
|---|---|---|
|SkyLight + 4556116|`WS::CAWindowContent::~CAWindowContent() + 356`|C28 L996|
|QuartzCore + 9256|`CA::Transaction::pop() + 88`|C28 L1010|
|QuartzCore + 10196|`CA::Transaction::commit() + 652`|C28 L1013|
|QuartzCore + 1705728|`CA::Render::Context::schedule_destroy()... + 24`|C28 L1029|
|QuartzCore + 512484 / 512476|`CA::Render::Context::destroy() + 2368 / 2360`|C28 L1030、C27 L985|
|QuartzCore + 1639116|`CA::Render::remove_every_observer(void*) + 132`|C27 L984|
|SkyLight + 786036|`WS::CA::callback::context_will_destroy(...) + 772`|C27 L987|
|QuartzCore + 277744|`CA::Render::remove_observer(...) + 88`|C27 L988|

W27/W28 主线程均经过窗口内容析构和事务提交；render-server 的大量样本经过上下文销毁、观察者移除；主线程部分样本等待同进程 render-server 线程。两个线程在约 5.5 秒观察中都消耗大量 CPU。因此更值得追查资源生命周期/清理负载，不能只将此描述为普通 Metal 合成热点，也不能断言为永久锁死或 GPU 故障。

### 不可连接的证据

- 27 日 C27 与 W27 相隔约 21 分钟；C27 归因 foofoil PID **37834**，W27 中只有 foofoil PID **46940**（L29919），后者运行约 819 秒，说明已更换进程。其主线程在运行循环等待，CPU `<0.001s`（L29931–29961）。不能称其一直在疯狂创建窗口。
- 28 日 W28CPU/C28 与 W28 相隔约 49 分钟。W28 foofoil PID 8110 主线程 12 个样本主要是运行循环/事务处理（L21222–21275），总 CPU 0.228 秒，不支持主线程忙循环或死锁判断。
- 两个 watchdog 全文均没有 `CursorUIViewService` 进程条目。只能说快照未见该服务，不能推定为何退出，更不能推定用户强退导致后续清理。
- W28 L21241 有来自 `Squirrel [53147]` 的 importance donation，W27/W28 均见鼠须管 1.1.2 进程。它支持加入输入法对照，不能证明鼠须管有 Bug，也不能确定故障前具体输入源。

## 代码路径与提交候选

当前工作区：common base `a999686d2d6c`，另有用户的 `overview-search`、`terminal-ssh` 分支。本次未修改这些分支。通过 GitButler `show a999686~N` 核对了最近 100 个第一父提交的时间、消息和改动文件；通过 `but diff` 检查了两个已应用分支。当前 CLI 的 `but diff` 不支持已落入 common base 的旧提交（返回 `Could not find target`），因此下表的旧提交归属基于提交文件记录/文件新增记录与现有源码，**没有声称逐行 blame 或完成历史二分**。

```text
终端创建 → TerminalSession.view（FoilTerminalView : LocalProcessTerminalView）
  → TerminalSurface.makeNSView → 异步 makeFirstResponder
  → FloatingWindow.sendEvent → handleTerminalKeyDown
      → 协商编码且 !hasMarkedText() → 直接发 PTY
      → 其他按键 → SwiftTerm.keyDown → interpretKeyEvents → NSTextInputClient

空箔 → HistorySearchView TextField + FocusState
  → onAppear 聚焦 / focusRequest 先 false 后 true
  → didBecomeKey、leftMouseUp 请求再次聚焦
  → 焦点丢失且仍为 key 空箔时恢复焦点

总览 → NSTextField.controlTextDidEndEditing
  → requestSearchFieldFocus → Combine 合并到下一次循环
  → focusSearch → makeFirstResponder

正文搜索 → SearchInput(NSSearchField)
  → focusRequest 变化时异步 makeKeyAndOrderFront / makeFirstResponder
  → 关闭时恢复正文 responder
```

|优先级|提交（本地时间）|已找到的机制与边界|下一项验证|
|---|---|---|---|
|P1|`1fb285f89686`，10-21 11:13，原生终端接入|新增 TerminalSession/TerminalFoilView 并接入 SwiftTerm。当前工程精确锁定 1.10.1；组合态探针失败。`TerminalFoilView.swift:151–158` 只在创建时异步聚焦，普通 update 不聚焦；没有找到空闲时主动反复激活 inputContext 的循环|禁用终端入口的对照构建，或与此提交前的可构建版本比较；同环境操作后等待|
|P1|`4817fa21344e`，10-26 16:29，CSI-u 键盘消歧|当前 `TerminalSession.swift:397–402` 用 `!hasMarkedText()` 判定能否绕开输入法；底层恒 false，保护失效。编码器对方向键、Escape、修饰回车等可返回编码。只在协商模式与按键到来时运行，单独不能解释空闲风暴|TUI 开启协商后，中文组合期间按方向键/回车/Escape；对照不经过协商编码的构建|
|P2|`51ad07c06593`，10-24 23:30，正文统一搜索|改动终端容器，新增 `FoilContentSearch.swift:533–558` 原生搜索输入。请求序号控制聚焦，无每帧聚焦证据|终端 ↔ 搜索栏切换，关闭搜索后切出应用并等待|
|P2|`75ba0f9c3d71`，10-23 14:35，原生 AppKit 总览|新增当前总览视图；`FoilExposeViewController.swift:378–387` 编辑结束时重新请求焦点，focusSearch 缺少显式 visible/key 检查。已有“当前 editor 就是 responder 则返回”的保护；dismiss 会释放模型/面板，未证实持久循环|记录 editing ended → focus request → makeFirstResponder 的次数，重点总览退出与切换应用|
|P2|`afa019c1f841`，10-26 17:57，空箔快速打开|改动 HistorySearchView；当前 `HistorySearchView.swift:254–270` 强制恢复聚焦。`HistorySearchWindowController.swift:165–191` 有 key-window、空白和 sheet 检查；终端配置面板也会使其 guard 失效，不能直接断言两个窗口抢焦点|记录空箔、终端配置、终端打开/关闭之间的焦点序列；只放松恢复焦点策略作单变量对照|

其他已审计路径：

- `FloatingWindow.swift:575–612` 在鼠标事件中设置边缘 `NSCursor`，不是已看到的文本插入 UI 创建栈；缺少时序对应，优先级低于输入/焦点。
- 三指移动在触摸事件中调用 `CGWarpMouseCursorPosition`，不是空闲定时器；按用户回忆暂降优先级。
- `TerminalSession.swift:108–116` 输出快照最多每 5 秒一次，且仅输出变化后安排，没有空闲持续自调度循环。
- 侧栏 `synchronizeNavigatorFocus` 仅在状态变化时发布；hover monitor 有 nil 防重复注册和卸载路径，未发现直接触发文本输入服务的循环。
- Web/Markdown 原生文本路径仍是备选，但没有故障时窗口内容清单，不能排除。
- 10-27 17:54 的重用终端历史、Markdown 文件名等，以及当前 SSH 分支，按**提交时间**不是两天共同现象的首选引入点；开发中未提交代码可能早于提交时间，不能绝对排除。原始报告没有记录源码 revision。

Apple 的[自定义文本视图光标说明](https://developer.apple.com/documentation/AppKit/adopting-the-system-text-cursor-in-custom-text-views)说明标准 NSTextField/NSTextView 自动接入系统文本光标，自定义 NSTextInputClient 需要相应接入。SwiftTerm 当前使用自绘 CaretView/CALayer，没有找到 NSTextInsertionIndicator 的显式创建，因此“看到 CursorUIViewService 就一定是终端自绘光标”并不成立。协议参见 [NSTextInputClient](https://developer.apple.com/documentation/appkit/nstextinputclient)。

## 已执行验证

1. 独立组合态探针 `probes/terminal-ime.swift`，链接现有构建中的 SwiftTerm.o，**未启动 Shell、未创建窗口**：

   ```text
   setMarkedText("ni", selectedRange: {2, 0})
   hasMarkedText=false
   markedRange={NSNotFound, 0}
   selectedRange={NSNotFound, 0}
   windowsCreated=0
   ```

   对照底层 `build/SourcePackages/checkouts/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift:830–881`：setMarkedText/unmarkText 空实现，hasMarkedText 恒 false。宿主没有覆盖这些方法。**这是可重复的组合态接口缺口，不是系统卡死复现。**

   ```sh
   xcrun swiftc -profile-generate -I build/Build/Products/Debug \
     docs/investigations/probes/terminal-ime.swift build/Build/Products/Debug/SwiftTerm.o \
     -o /tmp/foofoil-ime-probe -framework AppKit -framework CoreText -framework QuartzCore
   LLVM_PROFILE_FILE=/tmp/foofoil-ime-probe.profraw /tmp/foofoil-ime-probe
   ```

   当前 .o 带覆盖率插桩，首次未加 `-profile-generate` 链接失败；加上后成功、无链接警告。未改构建配置。

2. 11:10:53–11:11:23，保持现有应用状态、无主动浮箔操作，每 5 秒采集进程指标，共 7 次。CursorUIViewService 的 `ps %cpu` 均为 0，RSS 约 15.8–15.9 MiB；foofoil 0–6.3%；WindowServer 35.2–45.9%。**未复现**该服务风暴；系统中还有其他应用，不能用 WindowServer 数值归因浮箔。此次观察仅 30 秒，没有长时排除意义。

3. 只读 CGWindow 枚举：输入服务第一次可见清单内 9 个窗口、稍后 10 个，均非 onscreen。没有标题/内容采集。一次增加 1 个窗口不是泄漏证据；受权限与 API 可见性限制，清单不是系统内所有对象的完整账本。

4. 当前 `foofoil.debug.dylib` UUID 为 `047FC3F3-E6F9-304C-9FC6-DE88CC7ED85E`，与 W28 栈中的应用映像匹配；W27 是不同 debug dylib UUID。该匹配验证二进制身份，仍不提供源码 commit。未重编译或重启用户正在运行的浮箔。

5. 新记录器 1 秒冒烟运行通过，CSV 正确记录四类进程及带时区时间戳；临时目录中的轮转验证通过（仅保留最新文件及两份备份，表头正确）。没有跑 Xcode 单元/UI/全套测试：本次没有产品代码修改，也没有将接口探针成功当作系统问题已修复。

## 复现矩阵与定位顺序

所有完整 UI 组合尚未执行；环境按原始报告为 M1/16GB、macOS 27.0.1(26A434)。内屏+Redmi 外屏来自背景记录，本次未主动修改布局或缩放。

|组|单变量|状态/观测时间|
|---|---|---|
|A|完全退出浮箔，保留平时工作负载|未执行|
|B|浮箔现状、无主动操作|已观察 30 秒，未见服务 CPU 异常；未核实窗口内容类型|
|C|只开图片、无终端/搜索|未执行|
|D|打开终端但不输入，切去其他应用等待|未执行|
|E|终端中文输入/TUI 协商，结束操作后等待；英文输入源作对照|未执行|
|F|空箔/终端配置/总览/正文搜索分别切换焦点后等待|未执行|
|G|Markdown/Web，含/不含可编辑元素|未执行|
|H|只将同一组合改为单屏，随后比较跨屏|未执行|

先每组短时 1–2 分钟，使用记录器提前采集；一旦开始持续资源增长，停止操作并采样，不以等到再次登出为验收。退出实验使用正常关闭测试窗/退出浮箔，保存工作的前提下进行；不结束 WindowServer 或 CursorUIViewService。后续正常使用中的观察时长必须另记，不能把“几分钟没复现”当作好版本。

提交定位建议先做功能对照，再做历史二分：

1. 先明确 D/E 是否相对 C/A 显著改变输入服务 CPU、内存与窗口计数；同时记录之后的等待阶段。
2. 若定位终端：比较 `1fb285f89686` 前后，再比较 `4817fa21344e` 前后，保持搜索路径、输入源和 TUI 相同。后者隔离协商按键风险，前者界定终端接入边界。
3. 若只在 F 发生：按具体入口比较 `75ba0f9c3d71`、`51ad07c06593`、`afa019c1f841` 各自前后。总览含其他改动，不直接以“某个新版本好了”归因单一行代码。
4. 所有旧版本在隔离 checkout/单独输出目录构建，使用独立测试数据，防止旧版改写用户现有历史；不要在当前多分支工作区回退或丢弃他人改动。当前没有已证明健康的版本，也没有可重复坏版本，因此本次没有执行伪二分。

## 下次异常需要的证据与采集方法

新增 `scripts/diagnose-cursor-ui.py`，只读采集 pid、进程名、ps CPU、RSS 与时间戳，不收集窗口标题、正文、命令行参数或按键。默认运行一小时，最多一天；每 5 秒一次，最多三个约 2 MiB CSV，之后轮转。PID 变化可提示服务/应用重启。ps 百分比只是该工具的快照指标，不等于诊断报告的 CPU duration，也不是精确瞬时采样。

```sh
# 启动；Ctrl+C 停止。只在需要排查的一次使用过程中运行。
python3 scripts/diagnose-cursor-ui.py --duration 3600

# 操作前后各记录一次相关进程窗口计数；没有屏幕录制授权时完整性可能受限。
swift docs/investigations/probes/window-count.swift
```

CSV 默认在 `~/Library/Logs/foofoil-cursor-ui/metrics.csv`，保留的旧文件为 `.csv.1`、`.csv.2`。停止后可用 Finder 删除这三个文件完成清理；记录器不会安装后台服务或开机任务。

最有价值的新证据是**服务还在高 CPU 时**同时取得 foofoil、CursorUIViewService、WindowServer 的短 sample、窗口计数和指标时间线，外加当时输入源、操作前后窗口类型/数量。例（将 PID 替换为记录器中当时的 PID，每个进程只采一次）：

```sh
/usr/bin/sample <PID> 2 -file /tmp/cursor-ui-<PID>.sample.txt
```

sample 可能需要系统授权；本次未对系统服务执行该命令。失败时保留终端错误，不将失败描述为“空栈”。sample 可能包含本机路径，分享前检查脱敏。优先在明显卡顿前采集；新证据须明确是在强退/登出之前还是之后。

## 修改与交付

- 本次专用分支：`investigate-cursor-ui-windowserver`。仅新增本报告、两个独立探针和只读记录器；未提交、未推送。
- 未修改产品逻辑、依赖、用户设置、签名或系统服务；无产品修复可声称验收通过。仅文档/诊断工具变更，不执行会终止现有浮箔实例的 `./run`。
- 后续若先修复终端组合态，应以正常中文预编辑、候选提交/取消、TUI 特殊键和切出窗口为独立验收项；系统卡死仍须另外验证，不能用输入修复替代根因证据。


## 后续修复与 Spotlight 评估（2026-10-28）

### 终端组合输入修复

用户明确要求先修复已知问题，再继续日常观察。本轮在宿主 `FoilTerminalView` 内补齐 marked text 存储、UTF-16 选区/替换、属性文本提交、候选位置和取消/解除标记行为，不修改 SwiftTerm 依赖。预编辑复用一个普通 NSView 子视图绘制，不引入新窗口或另一个 NSTextInputClient；按 Apple 的 [unmarkText 约定](https://developer.apple.com/documentation/appkit/nstextinputclient/unmarktext%28%29?changes=_7_4_1&language=objc)接受当前预编辑，空 setMarkedText 用于清除。提交前不写 PTY；组合期间优先 interpretKeyEvents，避开上游直接编码方向键、Control 等的路径。

`TerminalFoilTests` 新增：UTF-16（含 emoji）与部分替换、候选位置、复用单个预编辑子视图、协商特殊键保护、真实 PTY 提交/取消/解除标记且不重复发送。原有样式持久化测试在浅色系统上会把深色测试背景按产品设计镜像，首次回归因此失败；将该测试数据固定为 `.dark` 后重跑，不修改外观产品逻辑。

针对 `TerminalFoilTests`、`TerminalKeyboardProtocolTests`、`ClipboardHistorySearchTests` 的联合回归：**43 个测试，45 次参数化在内的执行通过，0 失败**。结果：`build/Logs/Test/Test-foofoil-2026.10.28_11-26-23-+0800.xcresult`。未跑全套。编译还报告未修改文件中的 WindowConfig Sendable 警告，以及 Xcode 的无 AppIntents 依赖提示；没有终端修复代码的新增编译警告。

这些验证证明组合输入缺口得到修复，不证明 WindowServer 卡死已解决。真实鼠须管候选窗交互与长时空闲仍需用户观察。

### 是否可能与读取 Spotlight 剪贴板有关

**当前判断：时间上可能相关，读取器本身作为直接根因的证据较弱；搜索 UI 的焦点路径和极大索引的资源压力仍是候选。**

- 时间线相容：`5e93eaa45ffb`（10-27 13:45）引入系统剪贴板历史，`5aec70c95b8f`（14:43）优化解析，均早于当天 16:37 的服务 CPU 报告；不能按提交日期排除。
- `SpotlightClipboardStore` 用 Data(contentsOf:) 只读快照解析 `.store.db` 和 dbStr 表，不写系统索引、不 mmap 正在改变的文件，不创建窗口，也不调用 CursorUIViewService、输入法 API 或动态私有框架。
- `ClipboardHistoryReader` 是独立 actor；共享解析器与缓存串行访问。文件 stamp 未变时复用快照，页 SHA256 相同时不重新解压；逐页检查取消。`ClipboardHistorySearch` 只在进入搜索、显式刷新或活跃搜索收到应用激活通知时刷新，没有后台常驻定时轮询。每次键入筛选不重新读取数据库。总览退出与搜索 stop 会取消任务；普通空箔只在选择剪贴板 scope 时启动系统历史读取。
- 相关风险确实存在：每次索引 stamp 改变仍整份读取索引；记录缓存没有总字节数限制；图片附件在 reader 中提前读取，且先加载再做保留时长过滤；主线程筛选比较图片 Data、读取当前 NSPasteboard 和加载来源 App 图标可能增加延迟。它们可间接放大内存/I/O/显示负载，但与此前“系统输入 UI bootstrap、随后图层销毁”的栈不是直接对应。单页解压已有 32 MiB 上限，缩略图缓存另有 8 MiB/128 项限制；这不代表整个历史缓存有上限。
- 隐藏搜索 UI 若仍在恢复原生输入框焦点，可能触发输入服务，即使同一次功能使用也读了剪贴板。因此之后的 A/B 应区分“同样搜索 UI，不加载 Spotlight 历史”与“完全不打开搜索 UI”。不要仅凭停用整个功能后不复现就把原因认定为数据库读取。

本机只读独立测量（仅输出汇总，没有打印剪贴板正文、标题或附件路径；未修改索引）：

|指标|结果|
|---|---|
|`.store.db` 文件大小|21,270,528 bytes，约 20.3 MiB|
|dbStr 映射文件总量|1,835,356 bytes|
|首次解析|0.1383 秒，解码 1296 页，50 条剪贴板记录|
|相同解析器第二次读取|0.0196 秒，解码 0 页，50 条记录|
|无文本记录中首个图片附件|4 个，文件大小合计 5,414,283 bytes（只查元数据）|
|独立进程最高 RSS|103,727,104 bytes，约 98.9 MiB（含 Swift 运行时/解析临时内存）|

测量调用的是产品解析器，不包含真实 UI、NSPasteboard、缩略图解码、actor 快照组装的全部开销，也不是故障当时数据量；不能作为整条功能路径不会卡顿的证明。当前数据规模没有显示数 GB 或持续后台 CPU 的迹象。本轮不猜测性地修改或禁用剪贴板能力，保持用户继续观察时的变量较少。

### 用户追加的系统崩溃报告

文件 `/Users/dongchao/Downloads/崩溃报告102810.txt` 的首行是报告元数据，随后是 JSON，JSON 末尾另附硬件文本。用 JSONDecoder.raw_decode 解析后与本机 `WindowServer-2026-10-28-105126.ips` **结构化内容完全相同**；两文件非逐字节相同是因为附加硬件文本。incident 均为 `80FC03EC-B3DB-4B80-8E2D-F4EFB0B145C2`，captureTime 为 10:51:26.9201。

因此这是已分析事件的另一份导出，不是新增一次卡死或 kernel panic。其附加文本独立确认：内屏 2560×1600、Redmi 27 NU 报告 5120×2880、MirrorOff，均 Online。JSON thermalPressureLevel 为 Nominal；displayState=OFF 是终止时快照状态，不能单独推定睡眠/显示器断连导致故障。

JSON processByPid 快照进一步显示：foofoil PID 8110 主线程 TH_WAIT、等待 mach_msg；mds、mds_stores、corespotlightd 主线程均为 TH_WAIT，后两者距上次运行约 957 秒。WindowServer 主线程和 Core Animation render-server 则为 TH_RUN。这不是“Spotlight 正在持续解析导致桌面无响应”的支持证据；单次快照不能排除更早触发或其他工作线程的活动。CursorUIViewService 仍未出现在进程列表中。

最后显示验证：新增组合态专项在补全候选选区矩形后再次运行；此前已导出并人工检查浅色/深色两份预编辑截图，文字、下划线和光标可见。一次只指定方法名而未带 `()` 的筛选运行实际执行了 0 项测试，未计入通过数；已改用完整 Swift Testing 标识重新执行并核对实际测试条目。

最终组合态专项结果：`build/Logs/Test/Test-foofoil-2026.10.28_11-30-02-+0800.xcresult`，3 项实际执行通过，0 失败。原始 terminal-ime.swift 仍是上游 SwiftTerm 缺陷的基线探针，已在输出中明确排除宿主覆盖实现；宿主修复验证以 TerminalFoilTests 为准。

`./run` 构建、模块嵌入与启动成功（退出码 0），已确认新 Debug 浮箔进程运行。修复与诊断文件仍未提交/推送；当前可供用户继续日常观察。
