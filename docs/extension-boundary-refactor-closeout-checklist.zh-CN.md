# 扩展边界重构收尾 checklist

日期：2026-09-10  
状态：收尾阶段 0–2 已完成；阶段 3 代码与自动测试完成，待实机回归，阶段 3 尚未验收  
依据：[评审终稿](extension-boundary-refactor-review-final.zh-CN.md)

本清单是评审后的新增收尾工作，阶段编号不替代原重构计划的阶段 0–6。任务路径按对应仓库根目录理解。

## 执行规则

- 从最早未完成的收尾阶段开始；该阶段所有任务及验收通过后，再进入下一阶段。不得横跨阶段积累未完成项。
- 勾选代表整项完成且有证据，不代表仅写了代码。部分完成、失败、跳过、待用户听音分别记录，不勾选验收项。
- 已有实现先核验并复用，避免重复改动；保留用户工作区改动，不自动提交或重写提交历史。
- 每阶段填写末尾记录模板，并同步评审文档中已变化的判断。说明改动、相关测试、剩余风险与阻塞。
- 文档改动只检查链接和差异；源码改动运行相关测试与构建，并按 AGENTS 执行 `./run`。契约/Runtime 改动增加对应仓库测试和实际 ABI smoke。
- 必需硬件验证未完成时保留阶段未完成；可以继续该阶段的独立工作，不能跳到下一阶段。最终集成的手动结果不能预先勾选。
- 不自动清空本地开发数据；若确有必要，先记录范围、原因及可恢复方式。删除 P0 不得删除当前版本恢复保障。

## 已知基线

- [x] 当前 AGENTS 已明确：无历史用户，P0 支持窗口关闭，不支持旧宿主/新扩展交叉组合；无需重复请求同一决策。
- [x] 用户已在本任务确认此前 PCM 独立文件停顿及 CUE/PCM 崩溃问题解决。此为用户复验反馈，不外推为后续改动的硬件验证。

以上两项仅记录已确认事实，不表示下面任一阶段已验收。

## 收尾阶段 0：固定边界与恢复语义

对应评审 §1、§5.1、§5.6。

- [x] 记录 foofoil、extension-kit、hifi 分支、提交号、工作区改动及相关测试基线。
- [x] 盘点当前 P1 菜单、设备启用状态、恢复与 Runtime dispatch 对 P0 的实际依赖，列出迁移目标。
- [x] 明确外部文件 `extensionItemID`、容器项目 ID 的有效范围及持久化规则；不透明不等于跨会话稳定。
- [x] 明确恢复请求 `currentItemID` 如何在新 Session 中定位原曲目：由扩展保证可恢复标识或解释不透明恢复状态；选定最小方案，不让宿主解析私有 ID。
- [x] 定义映射失败、删除当前曲、删除后继及容器所有权的行为；明确删除当前曲后是否播完及后继选择。
- [x] 形成决策记录与测试场景，区分仅服务 P0 的断言和必须迁移的当前版本行为断言。
- [x] **验收：** ID/恢复/编辑语义无冲突，后续实现无需猜测持久化与删除行为，基线证据完整。

## 收尾阶段 1：能力门控与操作状态

对应评审 §4.1–4.3。

- [x] 阻止无 `ui.navigator-actions` 的非 Hi-Fi Provider 接收私有导航命令；分步清理时临时适配内部也校验 Provider。
- [x] 专用音频 UI 同时要求播放快照、音频家族及已协商 `media.transport`。
- [x] 通用呈现无 transport 时只读或隐藏媒体区，不能显示可交互媒体控件。
- [x] seek 发送前检查能力与动作可用性；拖动值优先留在交互状态，成功后更新快照。
- [x] 过期回包丢弃；任何回滚/失败刷新均验证会话与操作版本，不能覆盖后来的 seek、暂停或新会话。
- [x] 测试无导航能力的 activate/move、保留播放快照但无 transport、显式禁用 seek、连续 seek 与取消/过期结果。
- [x] **验收：** 无能力时不发请求、不修改权威快照；相关测试和宿主构建通过，源码修改后 `./run` 成功。

## 收尾阶段 2：ID 映射、恢复与队列所有权

对应评审 §4.4、§5.6，依赖阶段 0 的语义决策。

- [x] 落实 ID 生命周期；必要时将临时外部文件 ID 改为内存态，新会话重新映射，容器列表按新快照重新投影。
- [x] 当前版本重启/会话重建能恢复曲目和位置；临时 ID 改变、资源失效时有明确行为。
- [x] 映射失败且无删除意图时不裁剪扩展队列。
- [x] 用户删除当前曲或后继时按编辑意图更新序列，不因映射失败而继续已删除后继。
- [x] 单资源容器不受外部文件队列裁剪；宿主内部表达“不变/有效序列/无法映射”和必要删除意图，不为实现细节扩充公共契约。
- [x] 六类队列测试通过：映射失败、删除当前曲、删除后继、重排、多文件连续播放、单资源容器。
- [x] 验证实际 Runtime 消费队列后 `sequenceIDs` / `successors` 符合编辑结果；补齐当前版本恢复及资源替换测试。
- [x] **验收：** 宿主投影与 Runtime 后继一致，ID 生命周期与恢复测试通过；相关跨仓库检查及 `./run` 成功。

## 收尾阶段 3：关闭与独占交接失败

对应评审 §4.6（原 §5.5），合并阻塞项。

- [x] 需要竞争同一设备的会话替换显式等待旧会话关闭并处理失败；整理 didSet 兜底，避免重复关闭。
- [x] PCM 与扩展暂停/释放回调可向协调器传播错误，删除交接关键路径中的吞错行为。
- [x] 释放成功后才删除旧 owner；失败保留 owner 或等价待释放记录，阻止同设备新 start，保留重试所需上下文。
- [x] 幂等且明确可重试的释放错误至多重试一次；下一次请求不能绕过未释放状态。
- [x] 新获取失败、取消、旧界面消失和过期结果不遗失资源归属；不同设备及系统输出不受无关错误永久阻塞。
- [x] 失败提示可本地化，刷新失败有界；刷新结果不能覆盖新会话/新操作。
- [x] 故障注入覆盖 PCM → 扩展、扩展 → PCM、扩展 → 扩展：释放失败时新 start 为零、旧记录保留、恢复后重试成功；覆盖取消/过期/不同设备。
- [ ] 实机验证同 DAC 双向交接、快速切换、设备失效恢复、关窗/退出释放及系统默认输出，记录版本和设备。
- [ ] **验收：** 故障注入、相关测试、构建/`./run` 与本阶段实机回归均通过；失败不会静默进入新独占会话。

## 收尾阶段 4：菜单、动作状态与 P0 删除

对应评审 §5.1–5.3。

- [ ] hifi 的标准媒体/设备操作改由宿主 UI 与公共能力承接，不再贡献对应 `hifi.*` 菜单命令。
- [ ] `ui.commands` 只保留确有产品用途的自定义操作；没有此类命令则取消该能力。
- [ ] hifi 与宿主统一消费 `availableActions` 和公共设备快照，移除旧 command 的 `isEnabled` 读取。
- [ ] 按当前契约始终包含 `.refresh`；明确 `.selectDevice` 与设备连接状态的共同约束，不顺带改轮询协议语义。
- [ ] Runtime 公共媒体/生命周期/导航入口直接调用类型化动作或方法，移除旧命令字符串 dispatch；保留合法的插件内部不透明 ID/命名空间。
- [ ] 将关闭幂等、恢复位置、资源失效、设备错误传播等有价值断言迁入公共协议测试。
- [ ] 删除宿主 P0 适配、hifi 外部 P0 命令入口及仅服务 P0 的 fixture/测试；保留 C ABI v1 函数表及当前版本恢复。
- [ ] 验证旧协议明确被拒绝、当前公共协议成功，菜单/媒体键/设备菜单仍可用，普通 PCM 无 hifi 时可播放。
- [ ] 更新 smoke 的真实公共 fixture 参数、AGENTS/计划/支持文档，清除过时的继续兼容要求。
- [ ] **验收：** 菜单、设备状态与协议迁移一并完成，无新路径暗中依赖兼容层；三仓库相关测试、ABI smoke 与 `./run` 通过。

## 收尾阶段 5：扫描、通用容器与余项

对应评审 §4.5、§5.4、§6.1–6.3。

- [ ] 连续扫描预判只读声明，不逐项执行 sniff/probe；保留 Provider 偏好、优先级、启用与匹配规则，需要 sniff 的歧义作为边界单独解析。
- [ ] 盘点书签解析、文件存在检查和路径标准化等剩余 I/O；可能阻塞的操作移出主 actor，不将“不 probe”宣称为“完全无 I/O”。
- [ ] 必须执行的 probe 有配对资源访问作用域及后台执行边界；采用有界任务编排，取消停止后续扫描并丢弃旧结果，不假设能中断同步 C ABI。
- [ ] 测试至少 100 文件扫描、Provider 竞争/偏好、sniff 歧义、授权资源与取消；记录调用次数和主线程执行证据，性能结论以实测为准。
- [ ] 未知扩展容器使用通用呈现与宿主 ID，不显示 SACD，不解析 probe.reason；测试非 Hi-Fi 多曲目容器。
- [ ] 合并重复盖章，保留语义必要发布；删除无生产调用者辅助代码前迁移有价值的测试断言。
- [ ] 隔离测试 Provider/Host；使用共享单例时确保所有相关用例协调串行与 defer 注销，避免仅单个套件串行仍互相污染。
- [ ] **验收：** 扫描/授权/取消与通用容器测试通过，相关构建和 `./run` 成功，未增加未经证实需要的缓存或并发基础设施。

## 收尾阶段 6：最终集成与交付

对应评审 §7、§9。

- [ ] extension-kit：`swift test` 通过。
- [ ] hifi：`swift test` 与实际公共协议 Runtime smoke 通过，记录完整命令及 fixture 路径，不保留占位参数。
- [ ] foofoil：`xcodebuild test -project foofoil.xcodeproj -scheme foofoil -destination 'platform=macOS'` 通过；跳过项逐项注明，不能计为通过。
- [ ] `./run` 构建、插件注入/签名及启动成功；无新增编译警告，差异检查通过。
- [ ] 实机回归 PCM 系统/独占、同 DAC PCM/DSD 双向快速交接、DSF/DFF/SACD 播放/暂停/定位/切曲。
- [ ] 实机回归删除当前曲、删除/裁剪/重排后继后的续播，以及容器激活/呈现。
- [ ] 实机回归设备拔出/重接/忙碌/切换、关窗/退出释放、菜单与媒体键。
- [ ] 实机回归 PCM 独立文件同采样率连播、CUE 首次播放；自动覆盖 44.1 kHz 单/双声道，防止仅单声道测试掩盖默认格式路径。
- [ ] 汇总 foofoil/hifi/extension-kit 提交与工作区、设备型号或 UID、文件类型/采样率、操作与结果来源；不外推未测硬件。
- [ ] 按职责审查残留标识：通用宿主不含 Hi-Fi 特例/适配调用；允许配置、文案、测试及插件自身的不透明标识，不以全局字符串零命中代替审查。
- [ ] **最终验收：** 评审 §9 全部满足，所有必需手动验证通过；文档与实际状态一致，无未记录阻塞。

## 每阶段执行记录模板

完成某阶段时复制一份并填写，不用预测结果代替证据。

```text
阶段 / 日期 / 执行者：
三仓库分支、提交及工作区差异：
完成任务与关键行为变化：
测试命令 / 结果 / 失败与跳过：
构建、ABI smoke、./run（按适用范围）：
实机设备 / 文件类型与采样率 / 操作 / 结果来源（用户或 agent）：
未验证范围 / 风险 / 阻塞：
验收是否通过及证据：
下一阶段（仅在本阶段验收通过后）：
```


## 收尾阶段 0 执行记录（2026-09-10）

- 执行者：当前任务 agent。三仓库进入时均为 ext-fix、工作区干净，完整提交号见[阶段 0 决策记录](extension-boundary-closeout-stage0.zh-CN.md)。
- 完成：P0 依赖盘点、原始资源顺序下的公共恢复约定、会话内盖章、删除当前曲/后继/空列表/容器行为及测试迁移清单。仅修改文档。
- 验证：kit 26 项、hifi 43 项及 ABI smoke 通过；宿主 xcresult 为 219 通过、3 abort 失败、1 硬件跳过，完整命令/结果包/失败名称见决策记录 §6。
- 未运行 ./run 或新增实机听音：无源码/运行时改动。此前用户反馈保留为硬件基线，不替代本次测试结果。
- 阶段 0 验收通过：基线及语义已明确，失败如实登记；没有实施阶段 1。后续须复现/归因宿主 abort，不能把本记录理解为测试全绿。

## 收尾阶段 1 执行记录（2026-09-10）

- 执行者：当前任务 agent。仅 foofoil 有源码改动；extension-kit、hifi 保持 `ext-fix` 与进入时相同提交，工作区干净。基线：foofoil `fe320f2cfd1587a7e9348d72cf762ad5ac7cf74b`（阶段 1 改动尚未提交）、extension-kit `6a617c244bb00a7ade80cb7873eb759cc10eaf17`、hifi `334d71d03779f5bcf002984a3966b4b3c82a52d8`。
- 完成任务与关键行为变化：
  - 导航泄漏：`HiFiLegacyAdapter.navigatorRequest` 内部统一执行 `supports(session)` 校验；`InProcessContentProvider.perform(navigatorAction:)` 仅在 `HiFiLegacyAdapter.supports(session)` 为真时才走兼容层，通用 Provider 不再收到 `hifi.navigator.*`。
  - 音频 UI 门控：`ExtensionPlaybackSupport.usesHostAudioChrome` 现要求播放快照、内容家族为音频且已协商 `media.transport`（兼容期额外放行已协商的旧 Hi-Fi，避免破坏当前 hifi Runtime），新增 `showsInteractiveMediaControls` 判定通用呈现。
  - 通用呈现：`ExtensionPresentationView` 只在 `showsInteractiveMediaControls` 为真时显示可交互控件；否则显示只读进度，不提供播放区。
  - seek：`seekExtensionPlayback` 发送前检查 `MediaPlaybackRequest.isSupported`、`isSeekable` 与 `isActionAvailable(.seek)`，删除乐观写回；`AppState.extensionPlaybackOperationVersion` 在非 refresh 媒体动作时递增，完成回包校验会话 ID、`exclusivePlaybackGeneration` 与序号，过期/pause/新会话回包被丢弃。
- 测试：新增/调整 `HiFiLegacyAdapterTests`、`ExtensionPlaybackSupportTests`、`GenericAudioContractTests` 共 4 组断言（无导航能力 activate/move、音频家族无 transport、显式禁用 seek 不发送且不改快照、连续 seek 旧回包不覆盖新位置）。
- 测试命令 / 结果 / 失败与跳过：extension-kit `swift test` 26 项通过；hifi `swift test` 43 项通过；foofoil `xcodebuild test -project foofoil.xcodeproj -scheme foofoil -destination 'platform=macOS' -only-testing:foofoilTests` 通过，xcresult 汇总 230 项、229 通过、0 失败、1 硬件跳过（`CueSheetTests/exclusivePlaybackSurvivesTrackChangesAndPause()`）。阶段 0 的 3 个 abort 已由 `fe320f2` 修复，本次未复现。
- 构建、ABI smoke、`./run`：`xcodebuild build` 与应用 `./run` 均 `BUILD SUCCEEDED`，Hi-Fi Debug 插件注入并启动成功；未发现新增编译警告。本阶段未改 extension-kit/hifi 契约，未重跑 ABI smoke（其结果不受影响，最终阶段仍需完整 smoke）。
- 实机设备 / 文件类型与采样率 / 操作 / 结果来源：本阶段无硬件相关改动，未做新听音；PCM/CUE 用户复验保留为基线，不代表收尾改动已实机验证。
- 未验证范围 / 风险 / 阻塞：旧 Hi-Fi 兼容层仍在（阶段 4 删除），`usesHostAudioChrome` 对已协商的旧 Hi-Fi Provider 仍放行；未做真机导航/seek 手测。测试共享单例污染风险仍在，阶段 5 处理。
- 验收是否通过及证据：通过。三仓库相关测试全绿、宿主 0 失败、`./run` 成功；无能力路径不发请求且不改权威 `extensionSession`。
- 下一阶段（仅在本阶段验收通过后）：收尾阶段 2（ID 映射、恢复与队列所有权），依赖阶段 0 的语义决策。

## 收尾阶段 2 执行记录（2026-09-10）

- 执行者：当前任务 agent。仅 foofoil 有源码/测试改动；extension-kit、hifi 无改动、工作区干净。基线：foofoil 阶段 1 提交 `fc9e69c`（阶段 2 改动尚未提交）、extension-kit `6a617c2`、hifi `334d71d`。
- 完成任务与关键行为变化：
  - ID 生命周期：`FileListItem.extensionItemID` 改为会话内状态，不再写入/读取持久化；`containerTrackID` 仍按阶段 0 决策持久化用于恢复。`stampHostListWithExtensionQueueIDs` 先清除旧盖章再按新快照重新映射，避免“旧值恰好存在”被判为跨会话稳定。
  - 队列投影：新增 `HostPlaybackSequenceProjection`（`unchanged` / `sequence([String])` / `currentOnly(String)`），`sessionByApplyingHostPlaybackSequence` 不再把映射失败当成单曲裁剪；单资源容器恒为 `unchanged`，队列归扩展所有。
  - 显式删除：`AppState.extensionRemovedItemIDs` 记录当前会话内被删除的扩展项目 ID，只有它能触发 `currentOnly`；删除全部项目时关闭扩展会话并清空队列呈现；会话 ID 变化时清除删除意图。
- 测试：新增 `foofoilTests/ExtensionQueueProjectionTests.swift`：ID 编解码（extensionItemID 不持久化、containerTrackID 往返）、跨会话重新盖章、删除意图记录、六类队列场景、稳定 ID 恢复位置、ID 改变恢复、保存曲目缺失降级共 13 项。
- 测试命令 / 结果 / 失败与跳过：extension-kit `swift test` 26 项通过；hifi `swift test` 43 项通过；hifi 公共 lifecycle/media-navigation fixture ABI smoke 退出 0；foofoil `xcodebuild test ... -only-testing:foofoilTests` 通过，xcresult 汇总 243 项、242 通过、0 失败、1 硬件跳过（`CueSheetTests/exclusivePlaybackSurvivesTrackChangesAndPause()`）。
- 构建、ABI smoke、`./run`：`xcodebuild build` 与应用 `./run` 均 `BUILD SUCCEEDED`，Hi-Fi Debug 插件注入并启动成功；未发现新增编译警告（仅既有 AppIntents 元数据提示）。
- 实机设备 / 文件类型与采样率 / 操作 / 结果来源：本阶段无硬件相关改动，未做新听音。宿主投影与 Runtime 后继一致性来自单元测试与合成 fixture smoke，不冒充真机听音。
- 未验证范围 / 风险 / 阻塞：未实现按文件大小/修改时间的内容指纹比较；同一路径内容被替换且 fresh 仍含同 ID 时，恢复仍可能套用旧位置。当前只通过“fresh 队列不含保存 ID/临时 ID 改变”测试锁定可观察的降级行为，内容替换检测留待后续或阶段 6 评估。真机删除/重排续播、容器激活仍待最终手动回归。
- 验收是否通过及证据：通过本阶段的可自动化部分。宿主投影与 Runtime 后继在测试与 smoke 中一致，ID 生命周期与恢复测试通过，三仓库相关测试与 `./run` 成功；内容指纹检测缺口已如实登记。
- 下一阶段（仅在本阶段验收通过后）：收尾阶段 3（关闭与独占交接失败），依赖当前会话/队列语义。

## 收尾阶段 3 执行记录（2026-09-10）— 待实机回归，未验收

- 执行者：当前任务 agent。仅 foofoil 有源码/测试改动；extension-kit、hifi 无改动、工作区干净。基线：foofoil 阶段 2 提交 `0e9036f`（阶段 3 改动尚未提交）、extension-kit `6a617c2`、hifi `334d71d`。
- 完成任务与关键行为变化：
  - 协调器：`ExclusivePlaybackCoordinator` 的暂停/释放回调改为 `async throws`；只有释放成功才移除旧 owner，失败保留记录、抛出 `HandoffError.releaseFailed` 并阻止同设备 `start`；释放最多重试一次；取消/过期不触碰旧 owner；不同设备互不影响。
  - PCM：`AudioPlaybackController.pauseForExclusiveHandoff` 改为抛出，失败保留 `activeLeaseClientID` 供重试；`closeOutput` 只在释放成功后移除协调器 owner；交接失败写入可本地化 `deviceFailureMessage`。
  - 扩展：`AppState.pauseExtensionForExclusiveHandoff` 改为抛出，失败保留会话；交接失败写入本地化 `extensionHandoffFailureMessage`，并在音频/通用呈现中显示；成功后清除。
  - 关闭传播：`ExtensionHost.closeSessionAndWait` 改为 `throws`，`closeSession` 保留日志兜底；`extensionSessionCloseTask` 改为携带 `Result`，重建/打开流程在旧会话释放失败且新会话竞争同一独占设备时放弃安装新会话（`sharesExclusiveDevice` 判定），不同设备/系统输出不被永久阻塞。
  - 有界刷新：媒体动作失败后仅补发一次 `.refresh`；refresh 不再触发二次刷新，结果仍受会话 ID、`exclusivePlaybackGeneration` 与操作序号校验。
- 测试：新增 `foofoilTests/ExclusiveHandoffFailureTests.swift`：释放失败阻止新 start 且重试一次（参数化 PCM→ext / ext→PCM / ext→ext）、释放恢复后可交接、单设备失败不阻塞另一设备、取消不暂停/不启动、新获取失败不登记 owner、`closeSessionAndWait` 失败可观察、幂等关闭成功。
- 测试命令 / 结果 / 失败与跳过：extension-kit `swift test` 26 项通过；hifi `swift test` 43 项通过；foofoil `xcodebuild test ... -only-testing:foofoilTests` 通过，xcresult 汇总 250 项、249 通过、0 失败、1 硬件跳过（`CueSheetTests/exclusivePlaybackSurvivesTrackChangesAndPause()`）。
- 构建、ABI smoke、`./run`：`xcodebuild build` 与应用 `./run` 均 `BUILD SUCCEEDED`，插件注入并启动成功，无新增编译警告。本阶段未改 extension-kit/hifi 契约，未重跑 ABI smoke。
- 实机设备 / 文件类型与采样率 / 操作 / 结果来源：**未进行**。本阶段核心是独占设备释放失败路径，其真机行为（同 DAC 双向交接、快速切换、设备失效恢复、关窗/退出释放、系统默认输出）不能在无硬件时验证；此前用户复验不覆盖本阶段改动。
- 未验证范围 / 风险 / 阻塞：**实机回归未完成，按 checklist 执行规则阶段 3 不验收、不进入阶段 4**。故障注入使用测试闭包模拟释放失败，未在真实 HAL/hog 场景注入；`closeOutput` 的失败保留 owner 依赖控制器 `pauseForExclusiveHandoff`，窗口关闭后控制器可能已释放，重试路径需实机确认。
- 验收是否通过及证据：未通过。自动测试与构建/`./run` 通过，但实机回归缺失，验收项保持未勾选。
- 下一阶段（仅在本阶段验收通过后）：完成实机回归并记录设备/版本后才能进入收尾阶段 4。
