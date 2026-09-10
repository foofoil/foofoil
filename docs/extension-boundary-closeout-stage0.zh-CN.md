# 收尾阶段 0：基线、依赖与语义决策

日期：2026-09-10  
范围：仅盘点、基线验证及决策，不实施阶段 1–6 的源码变更。依据[评审终稿](extension-boundary-refactor-review-final.zh-CN.md)和[收尾 checklist](extension-boundary-refactor-closeout-checklist.zh-CN.md)。下文“决定”是后续实现要求，不宣称当前代码已满足。

## 1. 仓库基线与边界

进入本阶段时三仓库均为 `ext-fix`，`git status --short` 均为空。

| 仓库 | HEAD |
| --- | --- |
| foofoil | `632933dc861cc8313a167075f9a3e3b692446c40` |
| extension-kit | `6a617c244bb00a7ade80cb7873eb759cc10eaf17` |
| hifi | `334d71d03779f5bcf002984a3966b4b3c82a52d8` |

foofoil/AGENTS 已关闭未发布 P0 的支持窗口，不再重新询问此决策。不改变 C ABI v1 函数表、公共能力命名及 DoP-only 策略；保留当前版本重启、资源授权和会话恢复。没有清空开发数据的必要，本阶段不清数据。

extension-kit/AGENTS 仍有“既有宿主/扩展继续加载”的一般兼容要求，适用于公共 ABI/契约，不应据此重新引入已关闭的未发布 P0 支持。阶段 4 同步说明其范围。hifi/AGENTS 中部分硬件状态是旧记录，最终手动结论以具体版本的验证记录为准。

用户此前已确认 PCM/CUE 问题解决，本阶段未重做听音，不把该确认扩展为后续改动已验收。

## 2. 当前 P1 对 P0 的实际依赖及迁移目标

路径相对表内所标仓库，采用符号定位，避免行号随修改失效。

| 当前调用链 | 现有依赖 | 迁移目标 / 阶段 |
| --- | --- | --- |
| foofoil `App/AppDelegate+MenuSetup.appendExtensionCommands` → `AppDelegate+Actions.extensionCommandAction` → `AppState+ContentOpen.performExtensionCommand` | `HiFiLegacyAdapter.mediaAction` 将当前 hifi 菜单的私有命令转为公共动作 | 阶段 4 先取消 hifi 标准媒体/设备私有菜单贡献；标准操作走宿主 UI，保留通用自定义命令框架 |
| foofoil `ExtensionPlaybackSupport.isOutputDeviceEnabled` | 读取 `hifi.device.*` command 的 `isEnabled` | 阶段 4 同步迁移到 `availableActions` 与公共设备连接快照；refresh 始终可用 |
| foofoil `ContentProvider` 默认媒体实现、`InProcessContentProvider` 媒体/导航/生命周期/探测 fallback | 能力缺失时使用旧媒体、导航、恢复、关闭及 SACD 魔数适配；导航缺少 Provider 校验 | 阶段 1 阻断泄漏，阶段 4 删除 P0 fallback；无能力明确不支持，不能失败后改发旧命令 |
| foofoil `ExtensionSessionLifecycle.restorationRequest` | 当前公共恢复仍取保存队列的 `currentItemID` 和 position；并非整个恢复都是 P0 | 阶段 2 保留公共恢复，按 §3 验证身份、资源顺序与新映射；阶段 4 仅删除旧恢复分支 |
| hifi `Runtime.swift` 菜单创建/刷新与 `capabilitiesObject` | P1 仍有 `ui.commands` 和 `hifi.*` 菜单状态 | 阶段 4 先迁移公共动作可用性，取消没有剩余产品用途的 ui.commands 声明 |
| hifi `MediaActionMessages.runtimeCommand`、`RuntimeController.perform(lifecycle:)` / `perform(navigation:)` | 公共消息又转回 `perform(commandID:)` 的私有字符串 dispatch | 阶段 4 改为 Runtime 内部类型化动作/方法，后删除 callback 的外部旧入口 |
| hifi `RuntimeController.perform(commandID:)` | 每次命令读取宿主队列并修改 sequenceIDs；不只导航依赖该路径 | 阶段 2 修投影语义，阶段 4 类型化迁移保留后继更新/播放状态同步，不能只删 switch |

固定 Hi-Fi 应用级设备服务回退已经删除，不重做此迁移。插件自己的 Provider/贡献 ID、设备 UID、项目 ID 是合法命名，不作全局字符串替换。

## 3. ID 与当前版本恢复：采用最小稳定性约定

决定复用 `session.lifecycle` v1 的 `currentItemID` / position，不新增恢复 blob、全局资源 ID 或独立存储。稳定性必须写入契约说明并由 Runtime 测试证明，不能靠宿主识别字符串布局。

| 值 | 有效范围 | 保存/重建规则 |
| --- | --- | --- |
| 宿主 `FileListItem.id` | 宿主列表内身份 | 可持久化，与扩展项目 ID 分离 |
| 外部文件 `extensionItemID` | 当前会话到宿主列表的映射缓存 | 改为不编码；新会话清除旧盖章，依资源对应关系重新映射。不能因“旧值恰好存在”就复用 |
| 扩展队列 item ID / 恢复 currentItemID | 同一 Provider、同一当前扩展版本、相同资源集合及原始请求顺序、资源未发生可检测替换时可恢复 | 保存于扩展会话快照；新 Session UUID 不复用，ID 对宿主始终不透明 |
| 容器曲目 ID | 同一未变化容器内的曲目标识，按上述恢复约定有效 | 保存用于恢复；新会话返回新投影，宿主不把旧 containerTrackID 直接当新列表映射 |
| stateReference | 宿主保存扩展会话快照的键 | 不改成曲目 ID，也不扩充为第二套恢复数据库 |

选择这个受限约定是因为 hifi 当前外部文件 ID 为 `file:<请求序号>`，容器 ID 为 `track:stereo:<曲号>`。它们在相同请求上下文可重复，但资源重排或替换后同一字符串可能指向不同内容。此格式仅由 hifi 解释，不是公共协议要求。

后续恢复顺序固定为：

1. 保存完整原始 `ContentRequest.resources` 顺序、Provider/扩展版本上下文、队列当前 ID 和位置，以及宿主文件列表顺序。请求资源顺序与用户播放顺序分别保存，不能用裁剪后队列反推资源数组。
2. 重启先解析书签并验证资源上下文；记录可检测资源变更信息（文件身份如可用、大小、修改时间），比较失败或无法证明匹配时不能把旧位置套到可能不同的曲目。此为轻量一致性检查，不宣称能识别所有内容替换，也不做整文件哈希扫描。
3. 按保存的原始资源顺序建立 fresh session，再请求公共 restore；之后才投影新的宿主播放顺序。宿主列表重排不等于重排 fresh request。
4. 书签移动且可确认仍是同一文件时允许保留原槽位恢复；无法确认、资源缺失/替换、版本不符或 fresh 队列不含保存 ID 时，保留历史条目但标明不可恢复，允许重新打开，从起点暂停开始；不把保存 position 应用到任意默认曲目。
5. 恢复完成后重新盖章/投影，只有当前会话结果可以发布。恢复本身不自动播放，后续自动播放由宿主明确用户意图控制。

扩展若不能保证这一受限稳定性约定，不得假装精确恢复；在当前版本中明确报告不可恢复。跨扩展版本和任意重组资源的精确恢复不属于本轮要求。阶段 2 落实说明、必要元数据与测试；后续不能仅删 Codable 字段而遗漏此链路。

## 4. 编辑与队列决策

当前 `removeFileListItems` 删除当前项且仍有多项时立即激活剩余第一项；收尾沿用该明确行为，并补齐空列表/单项和异步竞态，不改成“删除后仍播放当前曲”。

| 触发 | 决定 |
| --- | --- |
| 映射失败，没有明确删除意图 | 不改 Runtime 后继；保持原队列并请求重建映射。不得将空映射当单曲或用户清空 |
| 删除当前曲，仍有其他项 | 停止旧曲并取消旧预排，立即选中剩余第一项；原本播放则按正常交接继续播放，原本暂停则保持暂停。不等待旧曲自然结束 |
| 删除当前曲后只剩一项 | 同上，可退为单文件呈现，但必须作废旧扩展后继，不能因 fileList 变 nil 丢失编辑意图 |
| 删除全部项目 | 停止并关闭会话/释放资源、清空队列呈现；不保留隐藏连播 |
| 仅删除后继 | 当前曲继续；从最新宿主顺序移除已删后继，剩一项时也显式传递“无后继” |
| 重排后继 | 当前曲不被重启；顺序模式从其新位置之后取可播放项，非顺序模式不预排未确定后继 |
| 顺序播放/列表循环 | 当前已打开序列只表达从当前项向后的有效项目；列表循环到头由宿主重新选择，避免 Runtime 与宿主重复循环 |
| 单曲循环/随机 | 不预排外部后继；宿主选定下一项后再下发动作，不让旧预排覆盖用户模式 |
| 单资源容器 | 内部顺序归扩展；宿主只投影，激活/移动/移除严格遵循 contribution 的 allowedActions。不支持的操作不能伪装为裁剪容器内部序列 |
| 宿主隐藏/删除容器投影 | 属于宿主列表编辑；不能改写原容器内部曲目。涉及当前播放时按删除当前项策略停/切，仍保留的容器内部顺序由扩展确认 |

实现采用会话 ID + 宿主编辑版本保护异步结果，区分“有效序列”“不改动”“映射失效”，显式删除意图不能由映射失败推测。编辑记录至少保留到当前会话已确认对应后继或已关闭，不能在折叠列表时丢弃。阶段 2 应消除暂停、刷新或迟到回包重新注入旧队列的路径。

## 5. 测试与 fixture 处置清单

以下是待实施测试，不是本阶段已通过的新行为。

| 现有来源 | 处理 | 保留的行为保障 |
| --- | --- | --- |
| HiFiLegacyAdapterTests 的 navigationUsesLegacyWireFormat | 删除 P0 编码断言，改为公共导航及旧命令拒绝 | 非 Hi-Fi 无动作能力不发私有命令、输入快照不被修改 |
| HiFiLegacyAdapterTests 的 sourceURL/containerTrack/invalidResourceID | 迁到通用映射测试，移除按私有字符串取资源的假设 | 队列裁剪仍定位正确授权文件，单容器使用其资源，无法映射明确降级 |
| ExtensionLifecycleTests 的 legacyClose/legacyRestore | 迁到公共 lifecycle；完成迁移后删 legacy 测试 | 等待关闭、幂等、恢复校验、正确曲目/位置、跨 Provider 不重放 |
| InProcessAudioDeviceService 请求/线程/失败测试 | 保留 | 原请求传递、后台执行、错误可观察；不是 P0 测试 |
| LegacySessionCommands.json | 阶段 4 删除 | 另加当前外部入口拒绝 P0 的测试 |
| HistoryAndQueueSnapshots.json | 逐条筛选，不整文件删除 | 当前版本窗口/队列恢复、资源顺序和单容器语义；删除仅旧格式迁移条目 |
| SessionLifecycleRequests / MediaNavigationRequests / ContentProbeRequests / AudioDeviceServiceMessages | 保留并随公共语义修订；检查是否含旧 command 状态断言 | 公共协议解码、能力/未知操作校验、ABI 一致性 |
| Runtime 内部旧 dispatch 与 smoke | 迁到类型化动作与公共消息后删旧执行路径 | 关闭记录保留、恢复范围、序列更新、pause/seek、设备错误；无硬件测试不伪装成听音 |
| CueSheetTests / PCM 连播测试 | 保留 | 44.1 kHz 单/双声道首次播放、独立文件与 CUE 实际边界、尾曲不截断 |

新增验收场景：

- 临时盖章改变但相同资源/原始顺序仍恢复原曲目和位置；新 UUID 与旧状态分离。
- 宿主列表重排后重启，原始 request 顺序不变；裁剪队列不改变资源槽位；同 ID 但资源替换不得误恢复。
- 书签迁移可确认同文件/不可确认、资源缺失、无对应曲目、损坏状态分别验证。
- 映射失败、删除当前曲、删除后继、清空、折叠成单文件、后继重排、模式切换、单容器六类基本场景及边界均锁定，迟到回包不恢复被删序列。
- 菜单/设备动作迁移前后均有公共能力校验，refresh 不被显式 availableActions 意外禁用。
- PCM → 扩展、扩展 → PCM、扩展 → 扩展释放故障均验证 owner 保留且新 start 为零。

## 6. 本阶段验证

本阶段运行现有测试以取得基线，不将它们作为尚未修复问题的验收。完整命令与结果见下方补记。没有修改源码、契约或引擎，因此不运行 `./run`，不发起新听音。

| 检查 | 本次结果 |
| --- | --- |
| extension-kit `swift test` | 26 项通过，退出 0 |
| hifi `swift test` | 43 项通过，退出 0 |
| hifi 公共 lifecycle/media-navigation fixture 经 ABI smoke | 退出 0；包含现存公共及内部旧路径，不代表 P0 清理已完成；未对合成数据播放或获取 DAC |
| foofoil 单元测试 | xcresult 汇总：223 项，219 通过、3 失败、1 跳过；参数化设备汇总 235 通过、3 失败、1 跳过；退出 65 |

命令（分别在对应仓库根目录）：

```sh
# extension-kit 与 hifi 各自执行
swift test

# hifi
swift run hifi-runtime-smoke --self-test \
  ../extension-kit/Sources/FoofoilExtensionKit/Fixtures/SessionLifecycleRequests.json \
  ../extension-kit/Sources/FoofoilExtensionKit/Fixtures/MediaNavigationRequests.json

# foofoil：本阶段只采集单元测试基线，最终阶段仍需完整 test
xcodebuild test -project foofoil.xcodeproj -scheme foofoil \
  -destination 'platform=macOS' -only-testing:foofoilTests
```

宿主失败报告均为 `Test crashed with signal abrt.`：

- `ExtensionKitTests/navigatorPanelAppearsWhenPointerIsInsideWindowOnHover()`
- `CueSheetTests/sequentialSameRateTracksFinishAtPlaybackBoundaries(cue:channels:)`
- `FoofoilTests/testAudioPresentationSizeUsesArtworkAspect()`

不能把同一测试进程中的三个受影响用例直接解释成三个独立源码缺陷；本阶段未定位 abort 根因，未据此前用户听音通过而忽略本次失败。硬件跳过项为 `CueSheetTests/exclusivePlaybackSurvivesTrackChangesAndPause()`。本次构建日志未检出 warning/error 文本，但测试运行失败，绝不写成全绿。

本机证据：`/tmp/closeout0-kit.log`、`/tmp/closeout0-hifi.log`、`/tmp/closeout0-smoke.log`、`/tmp/closeout0-host.log`；宿主结果包为 `/Users/dongchao/Library/Developer/Xcode/DerivedData/foofoil-gefngjvcphehzkbbnrrtuvsfmxrc/Logs/Test/Test-foofoil-2026.09.10_16-09-57-+0800.xcresult`。统计以 `xcrun xcresulttool get test-results summary --path <上述结果包>` 为准，不以控制台行数估算。临时日志可能清理，关键结论已记入本文。

## 7. 阶段验收与交接

阶段 0 的要求是完成盘点、确定语义并取得可重复基线，不要求在本阶段修复全部基线失败。上述决策已覆盖 P0 依赖、ID 有效范围、恢复顺序及明确编辑行为；因此阶段 0 验收完成。

仍未完成：阶段 1–6 的全部源码实施；宿主测试 abort 根因；新收尾改动的硬件回归。本阶段不进入阶段 1。下一阶段开始时应先确认宿主测试运行条件并复现/归因本次 abort；若仍影响相关验收，作为该阶段明确阻塞处理，不通过删测试或沿用旧通过结果跳过。阶段 0 的完成不代表整个收尾测试通过。

## 8. 基线故障修复补记

后续排查已找到原 abort 的具体调用链：2026-09-10 16:10:30 测试进程报告中，`NSWindow.dealloc` → 视图解绑/SwiftUI update → `CustomTextEditor.Coordinator.configureFocus` → `observedWindow` 弱引用赋值 → `weak_register_no_lock` → `_objc_fatal`。这是窗口销毁重入时重新观察即将销毁窗口的问题，不能按被报告的三个在运行用例分别归因为音频/封面/导航缺陷。

修复将窗口获取及监听注册延后至主队列，避免在当前销毁调用栈读取旧 window；用更新代次废弃过期焦点任务，在 `dismantleNSView` 中解绑 delegate、移除监听并禁止已排队焦点/高度更新继续操作。没有增加全局强引用保活、关闭测试并行或删除原测试，也没有改 PCM/DSD 引擎。

新增 `TextEditorFocusLifecycleTests` 覆盖：视图更新中不立即读 window；拆卸后不更新绑定且清除 delegate；真实 NSWindow 释放期间触发编辑器焦点配置仍能完成销毁。测试需要区分 AppKit 自身的 window 读取与被测同步调用，不能把框架自动布局的正常读取也判为失败。
