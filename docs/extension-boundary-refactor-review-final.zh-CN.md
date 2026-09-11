# 扩展边界重构评审终稿

日期：2026-09-10  
状态：收尾阶段 0–3 已完成，阶段 4 尚未开始；进度见[收尾 checklist](extension-boundary-refactor-closeout-checklist.zh-CN.md)
评审范围：`foofoil`、`extension-kit`、`hifi` 当前 `ext` / `ext-fix` 实现相对各仓库 `main` 的职责与行为变化

## 1. 评审前提

本项目仍在开发且尚未发布，没有历史用户、已发布插件或生产数据需要兼容。本文据此采用以下前提：

- 不要求兼容早期开发版本保存的窗口、历史、队列或容器数据；必要时可以清除本地开发数据，但本计划不要求自动清空数据；确有需要时先记录具体范围、原因及可恢复方式。
- 不要求支持旧宿主与新扩展、或新宿主与旧扩展的交叉组合。
- 当前 C ABI 和公共 JSON 契约仍应保持稳定、清晰和版本化，但没有必要继续支持尚未发布的 P0 私有命令协议。当前 AGENTS 已明确关闭 P0 支持窗口；后续落实依赖迁移与删除，不重复要求用户确认同一决策。
- 应用重启、当前版本数据恢复和同一版本内的会话重建仍属于正常产品行为，不能因为没有历史用户而忽略。
- 评审重点是职责边界、协议通用性、状态一致性、资源生命周期与行为可靠性，不以代码行数变化判断成败。
- 本文结论来自静态代码审查；硬件、性能和真实播放结果仍需按第 7 节验证。

## 2. 总体结论

本轮重构的架构方向正确，主要边界已经建立：

- 宿主通过 `session.lifecycle`、`media.transport`、`ui.navigator-actions`、`content.probe` 和 `audio.device-selection` 等公共能力使用扩展。
- SACD 探测、DSD/SACD 私有曲目标识解释、播放引擎和设备策略主要归属 hifi。
- 固定 Hi-Fi 设备服务查找已删除，普通 PCM 在设备服务不可用时保留系统输出路径。
- 宿主扩展代码已按 Runtime、Management、Presentation 和 Compatibility 分类，视图与播放控制适配器也已拆分。
- 非 Hi-Fi 测试 Provider 已证明公共契约可以表达播放、导航、恢复和关闭，不只是替换私有命令前缀。

当前未发现会使唯一现有 hifi 主流程必然无法工作的致命缺陷，但仍有五项应作为合并阻塞问题处理：私有导航命令可能泄漏给其他 Provider、音频控件缺少完整能力门控、seek 乐观更新可造成状态不一致、队列映射失败可能破坏后继序列，以及关闭/设备交接错误不能完整传播（§4.6）。内容探测的同步 I/O 与授权范围也应在合并前至少完成低成本修复和验证。

收尾阶段 1 已关闭其中三项：导航泄漏、能力门控与 seek 状态一致性（§4.1–4.3）。收尾阶段 2 已关闭队列映射（§4.4）与 ID 生命周期（§5.6）。收尾阶段 3 已关闭关闭/设备交接错误传播（§4.6），自动测试与实机回归均通过。连续扫描（§4.5）仍未处理。

此外，P0 兼容协议没有发布服务对象，支持窗口已关闭，应按依赖顺序落实删除。但当前新宿主与新 hifi 仍通过扩展菜单实际使用部分 `hifi.*` 命令映射，因此不能直接把整个兼容目录当作死代码删除；应先迁移菜单贡献和 hifi Runtime 内部 dispatch，再完成清理。

## 3. 已核对通过的部分

- `audio.hifi`、`hifi.*`、`SACDMTOC` 字面量在宿主生产 Swift 源码中已集中到 `foofoil/ExtensionSupport/Compatibility/`；其他相关命中主要是文案、SF Symbol、配置和测试。
- `isHiFiDeviceServiceAvailable`、`performHiFiDeviceCommand`、`releaseHiFiPCMOutputAndWait`、`ExtensionHost.hiFiExtensionID` 等固定 Hi-Fi 宿主 API 已删除。
- 公共媒体、生命周期、导航和探测消息的字段与 hifi 解码类型基本对应；未知枚举会被拒绝。
- hifi 关闭失败时不再先删除 Runtime 会话记录，保留了重试所需状态。
- 设备服务按 `audio.device-selection` Manifest 能力和 audio 域偏好发现；没有唯一候选时不使用扩展设备服务。
- hifi 的文件集合顺序会通过 `record.sequenceIDs` 影响 `record.successors`，公共队列可以驱动后继播放，但宿主投影失败时的输入仍需修正。

## 4. 合并阻塞问题

### 4.1 未协商导航动作时可能向任意扩展发送 Hi-Fi 私有命令

收尾阶段 1 已按分步清理路径处理：`HiFiLegacyAdapter.navigatorRequest` 内部统一执行 `supports(session)` 校验，`InProcessContentProvider` 也仅在 `supports(session)` 为真时才走兼容层，无 `ui.navigator-actions` 的通用 Provider 不再收到任何私有导航命令。P0 导航入口的彻底删除仍留待阶段 4。下文为原始问题描述。

位置：

- `foofoil/ExtensionSupport/Runtime/InProcessContentProvider.swift:114-130`
- `foofoil/ExtensionSupport/Compatibility/HiFiLegacyAdapter+Navigation.swift:6-30`

当会话没有协商 `ui.navigator-actions` 时，`InProcessContentProvider.perform(navigatorAction:session:)` 会调用 `HiFiLegacyAdapter.navigatorRequest`。该适配方法只检查 contribution ID 是否存在，没有检查会话是否属于 Hi-Fi，随后可能生成 `hifi.navigator.activate` 或 `hifi.navigator.move`。

因此，任何提供导航 contribution、但没有声明动作能力的非 Hi-Fi 进程内扩展，都可能收到 Hi-Fi 私有命令。当前只有 hifi 一个真实扩展，所以问题尚未在产品路径暴露，但它直接违反本轮重构的核心边界。

修复建议：

- 按第 5.1 节删除 P0 导航入口；未协商 `ui.navigator-actions` 时返回明确的不支持，不构造任何私有命令。
- 如果 P0 清理分多步实施，在删除前先让 `HiFiLegacyAdapter.navigatorRequest` 内部统一执行 `supports(session)` 校验。
- 增加非 Hi-Fi Provider 测试：提供导航 contribution、不声明 `ui.navigator-actions`，执行 activate 和 move，断言 Runtime 不收到 `hifi.*`。

### 4.2 音频 UI 与通用呈现都缺少完整能力门控

收尾阶段 1 已处理：专用音频界面固定为播放快照、音频家族与已协商 `media.transport` 三者同时满足；通用呈现按 `MediaPlaybackRequest.isSupported(by:)` 门控，可交互媒体控件在有快照但无 transport 时退化为只读状态。旧 Hi-Fi 兼容期仍额外放行已协商的 hifi Provider，待阶段 4 删除。下文为原始问题描述。

位置：

- `foofoil/ExtensionSupport/Presentation/ExtensionPlaybackSupport.swift:8-14`
- `foofoil/ExtensionSupport/Presentation/ExtensionPresentationView.swift:54-119`
- `foofoilTests/ExtensionPlaybackSupportTests.swift:89-95`

`usesHostAudioChrome` 在解析到 `contentFamily == .audio` 后直接返回 `true`，不再要求会话已协商 `media.transport`。因此，有播放快照但没有媒体控制能力的音频 Provider 会进入宿主音频界面，点击控件后才失败。

仅修改 `usesHostAudioChrome` 还不够。通用呈现路径只要发现 `session.mediaPlayback`，也会显示播放、暂停、前后切曲和 seek 控件，并发送相同的媒体动作。无 `media.transport` 的会话即使退出专用音频界面，仍可能得到不可执行的控件。

修复建议：

- 专用音频界面的规则固定为：存在播放快照、`contentFamily == .audio`、并已协商 `media.transport`。
- 通用呈现只有在 `MediaPlaybackRequest.isSupported(by:)` 为真时才显示可交互媒体控件。
- 有播放快照但无 transport 能力时，只显示只读状态或不显示播放区域，不能发送媒体动作。
- 修改现有测试，使会话保留播放快照但关闭 `media.transport`，分别验证专用音频界面与通用呈现。

### 4.3 seek 乐观更新绕过显式动作禁用

收尾阶段 1 已处理：`seekExtensionPlayback(to:)` 发送前校验 `media.transport` 能力、`isSeekable` 与 `isActionAvailable(.seek, in:)`，不再乐观写回 `extensionSession`，拖动值只保留在 Slider 交互状态；`AppState.extensionPlaybackOperationVersion` 在非 refresh 媒体动作时递增，完成回包校验会话 ID、`exclusivePlaybackGeneration` 与序号，过期回包直接丢弃。并发连续 seek 与显式禁用 seek 已有测试锁定。下文为原始问题描述。

位置：

- `foofoil/AppState/AppState+ContentOpen.swift:1048-1057`
- `extension-kit/Sources/FoofoilExtensionKit/MediaPlaybackContracts.swift:47-58`
- `extension-kit/Sources/FoofoilExtensionKit/MediaTransport.swift:97-104`

`seekExtensionPlayback(to:)` 只检查 `isSeekable`，没有检查 `MediaPlaybackSnapshot.allows(.seek)`。它先把 position 写回 `extensionSession`，然后发送 seek。当扩展通过 `availableActions` 显式禁用 seek 时，请求会被契约校验拒绝，失败只写日志，宿主乐观位置不会回滚。

修复建议：

- 发送前检查 `ExtensionPlaybackSupport.isActionAvailable(.seek, in: session)`。
- 拖动位置保留在 Slider 的交互状态，扩展成功返回后再更新会话快照。
- 优先采用只更新交互状态的方案。若保留乐观更新，失败或取消时仅允许在会话 ID 和操作版本仍匹配、且没有更新操作覆盖时回滚。过期回包直接丢弃，不恢复旧快照；失败后刷新也必须遵守相同版本校验。
- 增加 `availableActions` 不含 seek 的测试，断言不发送请求且不修改会话位置；补充连续 seek、seek 后暂停/换会话、失败和过期回包不能覆盖新状态的测试。

### 4.4 队列映射失败可能把扩展后继序列裁成单曲

收尾阶段 2 已处理：宿主新增内部 `HostPlaybackSequenceProjection`，区分“不变”“有效序列”“映射失效/显式删除”，映射失败保持原扩展队列不再裁剪为单曲；单资源容器恒为不变；`extensionRemovedItemIDs` 只记录宿主显式删除，只有它能触发当前项收尾。宿主投影与 Runtime 后继由单元测试和公共 fixture smoke 覆盖。内容指纹级的资源替换检测尚未实现（见 checklist 阶段 2 记录）。下文为原始问题描述。

位置：

- `foofoil/ExtensionSupport/Presentation/AppState+ExtensionQueue.swift:39-58`
- `foofoil/AppState/AppState+ContentOpen.swift:982,1010,1077`
- `hifi/Sources/HiFiExtensionRuntime/Runtime.swift:565-587`

`sessionByApplyingHostPlaybackSequence` 无法在宿主文件列表中映射当前扩展项目时，收集到的 ID 为空，随后把队列替换为当前单曲。该快照随媒体或导航操作发送给 hifi 后，Runtime 会据此覆盖 `record.sequenceIDs`，导致 `record.successors` 为空并打断后继播放。

用户确实删除后继文件和宿主暂时无法映射不透明 ID 是两种不同状态。前者可以裁剪，后者不应破坏扩展队列。当前实现用空结果同时表示两者。

修复建议：

- 先按 §5.6 确定 ID 生命周期与重建映射，再修改队列投影。
- 没有明确删除意图、仅因映射失效无法定位当前项时保留原队列，不能把不确定性解释为单曲序列。
- 用户明确删除当前曲或后继时，应依据宿主已记录的编辑意图更新后继，不能以“当前项无法映射”为由保留已删除的序列。明确当前曲是否允许播完及接下来播放什么，并用测试锁定。
- 只有宿主能够明确表达有效后继顺序时才覆盖 `playbackQueue.items`。使用宿主内部结果区分 `unchanged`、`sequence([String])`、`unmappable`，另保留足以识别显式删除的编辑状态；具体类型以最小实现为准，不加入 extension-kit。
- 单资源容器队列由扩展拥有，宿主只投影和转发动作，不按外部文件列表规则裁剪。
- 增加当前 ID 无法映射、用户删除当前曲、删除后继、重排、多文件无缝播放和单资源容器六类测试。

### 4.5 连续文件扫描可能在主线程同步执行 probe

位置：

- `foofoil/ExtensionSupport/Presentation/AppState+ExtensionQueue.swift:7-23`
- `foofoil/ExtensionSupport/Runtime/InProcessContentProvider.swift:39-65`
- `foofoil/ExtensionSupport/Runtime/ProviderResolver.swift:166-175`

连续文件收集会同步为列表项执行 Provider resolution。候选匹配可能调用 `content.probe`，通过 C ABI 执行扩展代码并读取文件。该调用来自主 actor 上的打开流程，在大列表、网络盘或慢速外置存储上可能造成界面卡顿。

正式创建会话时，`ProviderResolver.makeSession` 会建立 `ExtensionResourceAccessScope`；连续列表预扫描没有同等作用域。依赖 security-scoped bookmark 的 URL 可能因探测无权限而被误判为格式不匹配。

建议优先采用小改动，而不是立即引入缓存或复杂并发：

1. 为连续序列扫描增加只读取 Manifest 声明、不执行 sniff/probe 的预判入口。
2. 通过扩展名和内容家族预判，保留 Provider 偏好、优先级、启用状态与匹配规则。需要 sniff 才能确认的候选作为边界单独解析，不在预判中宣称已匹配；覆盖竞争 Provider 和歧义情况。
3. 对任何仍需执行的 probe 建立明确资源访问作用域，并移出主 actor。
4. 使用有界、可取消的结构化任务编排，不增加无界 `Task.detached`。同步 C ABI 一旦开始不能靠取消 Task 强制中断；取消应阻止后续扫描并丢弃过期结果，访问权保持到调用真正结束。
5. 只有实测仍有重复 I/O 问题时，再按 Provider ID、标准化 URL、文件大小和修改时间增加缓存。

“扫描不执行 probe”不等于“扫描完全无 I/O”：`resolvedURL` 的书签解析、文件存在检查与路径标准化仍可能访问存储，须另行盘点并将可能阻塞的操作移出主 actor。普通继承主 actor 的 Task 也不自动把同步调用移到后台。

该问题静态上能确认同步 I/O 和授权风险，但实际卡顿程度需要性能测试量化。合并前至少应完成前两项低成本短路，并补充大列表测试。

### 4.6 关闭与设备交接错误必须贯穿整个生命周期链

收尾阶段 3 已实现并由用户实机复验通过：协调器释放回调改为可抛出，只有释放成功才移除旧持有者，失败保留记录、最多重试一次并阻止同设备新 start；PCM 与扩展暂停路径不再 `try?` 吞错；`closeSessionAndWait` 可抛出，`extensionSessionCloseTask` 携带 `Result`，旧会话释放失败且新会话竞争同一独占设备时放弃安装；失败提示本地化，媒体失败后有界刷新一次且受会话/序号校验。故障注入测试覆盖 PCM→ext / ext→PCM / ext→ext、恢复、取消与不同设备。实机回归覆盖同 DAC 双向快速交接、设备失效恢复、关窗/退出释放与系统默认输出；期间修复了系统默认输出改采样率导致引擎停止而 UI 仍显示播放的回归（监听 `AVAudioEngineConfigurationChange` 后重排续播）。下文为原始分析。

位置：

- `foofoil/ExtensionSupport/Runtime/ExtensionHost.swift:160-175`
- `foofoil/AppState/AppState.swift:54-71`
- `foofoil/AppState/AppState+ContentOpen.swift` 的会话替换与 `pauseExtensionForExclusiveHandoff`
- `foofoil/AudioPlaybackController.swift` 的 `pauseForExclusiveHandoff` 与 `ExclusivePlaybackCoordinator`

`closeSessionAndWait` 当前吞掉错误，只写日志。hifi 释放失败时会保留 Runtime 会话以便重试，但宿主随后可能继续接管同一设备。

不能只把 `closeSessionAndWait` 改成 `throws`：当前旧会话关闭主要由 `extensionSession.didSet` 创建的 `Task<Void, Never>` 串行执行，观察器无法把失败返回给发起打开或设备交接的操作。

此外，协调器的旧持有者暂停回调是 `async -> Void`，PCM 与扩展暂停/释放路径用 `try?` 忽略错误，协调器在等待释放前移除旧持有者记录。仅修改 close 方法不能阻止释放失败后继续获取设备。

建议一起调整完整调用链：

- 需要接管同一独占设备时，在设置新 `extensionSession` 之前显式 `await` 旧会话关闭。
- 关闭成功后再安装新会话；释放失败时阻止同设备新的独占获取并显示可本地化提示。
- 协调器的暂停/释放回调能返回失败。仅在释放成功后清除旧持有者；失败保留持有者或等价的待释放记录，阻止该设备的新获取，保留重试入口。
- 对明确可重试且幂等的释放错误至多重试一次，不无限循环；不能通过清空 owner、吞掉前序错误或开始下一次请求绕过未释放状态。
- 新获取失败、取消和旧会话已离开界面的情况也要有明确资源归属，不丢失待释放记录。
- 普通系统输出和不竞争同一设备的内容切换不应被无关关闭错误永久阻塞。
- `didSet` 只保留不要求错误传播的兜底清理，或彻底移除其中的异步资源生命周期职责，避免双重关闭。
- 媒体操作失败后可有界刷新扩展快照；刷新本身遵守会话与操作版本校验，失败可观察，不无限重试。
- 故障注入覆盖 PCM → 扩展、扩展 → PCM、扩展 → 扩展：释放失败时新 start 调用次数为零，旧记录仍存在；恢复后可重试成功。另测取消、过期结果及不同设备/系统输出不被误阻塞。

## 5. 设计收尾与重要建议

### 5.1 关闭 P0 支持窗口，但先迁移当前仍在使用的菜单命令

位置：

- `foofoil/ExtensionSupport/Compatibility/`
- `foofoil/App/AppDelegate+MenuSetup.swift:530-559`
- `foofoil/App/AppDelegate+Actions.swift:25-28`
- `foofoil/AppState/AppState+ContentOpen.swift:962-969`
- `hifi/Sources/HiFiExtensionRuntime/Runtime.swift:366-392`

项目没有已发布的 P0 宿主或扩展，因此 P0 支持窗口已按当前 AGENTS 关闭；本阶段落实代码清理。不过兼容层并非全部未执行：当前 P1 hifi 仍声明 `ui.commands` 并返回包含 `hifi.*` 的 commands；宿主扩展菜单点击后，`performExtensionCommand` 会通过 `HiFiLegacyAdapter.mediaAction` 把这些命令翻译为公共媒体动作。

建议按以下顺序清理：

1. hifi 不再为播放、暂停、定位、前后切曲和设备选择贡献 `hifi.*` 菜单命令；这些操作使用已有宿主媒体 UI 和公共能力。
2. `ui.commands` 只保留公共媒体契约无法表达、且确有产品用途的扩展自定义命令；没有此类命令时可取消该 capability。
3. 先将旧测试中的当前版本行为保障迁移到公共协议测试（关闭幂等、恢复曲目/位置、资源失效、设备错误传播），再删除旧适配、仅服务 P0 的 fixture 和专用测试。不得整批删除仍有行为验证价值的测试。
4. hifi 的 `performCommandCallback` 只接受当前公共 command ID，不再接受外部 `hifi.*` 消息。
5. 保留 C ABI v1 函数表，不因删除旧 JSON 语义而无理由修改 ABI。
6. 更新 AGENTS、重构计划和扩展支持文档，删除继续保留 P0 的要求。

删除兼容层前必须完成第 1 步、§5.3 的设备状态读取迁移及当前版本恢复测试迁移，否则当前扩展菜单会从可用变成无响应或消失。

### 5.2 将 hifi 内部执行从旧协议字符串改为类型化动作

位置：

- `hifi/Sources/HiFiExtensionRuntime/MediaActionMessages.swift:24-33`
- `hifi/Sources/HiFiExtensionRuntime/Runtime.swift:103-154,488-549,592+`

当前公共 `media.transport` 被解码后，又通过 `MediaPlaybackMessage.runtimeCommand` 映射成 `hifi.play` 等字符串；生命周期恢复直接调用 `hifi.pause` 和 `hifi.seek`，导航也复用 `hifi.navigator.*`。因此，只关闭 callback 的外部旧命令入口可以消除协议兼容，但 hifi 内部仍依赖旧协议命名。

建议：

- 引入 hifi Runtime 内部枚举或类型化方法表达 play、pause、seek、previous、next、refresh、selectDevice、activate 和 move。
- 公共媒体、生命周期和导航消息直接调用内部动作，不再绕回 `perform(commandID:)`。
- 删除 `MediaPlaybackMessage.runtimeCommand` 及 Runtime 内部 `hifi.*` dispatch 字符串。
- 删除旧命令字符串 dispatch 是可维护性改进，不代表插件不能有私有命名。hifi 可以保留自己的 Provider/贡献 ID、不透明项目 ID 与内部命名空间；宿主不解释这些值。不能用全局禁止 `hifi.*` 字符串代替职责审查。

这项可与 P0 清理一起完成，避免形成“外部协议已通用、内部仍以旧协议为核心”的长期结构。

### 5.3 统一媒体动作可用性的状态来源

位置：

- `foofoil/ExtensionSupport/Presentation/ExtensionPlaybackSupport.swift:45-61`
- `hifi/Sources/HiFiExtensionRuntime/Runtime.swift:1014-1100`

公共契约允许扩展显式提供 `availableActions`，缺省时宿主根据状态、`isSeekable` 和队列长度推导。hifi 当前不发送该字段，宿主设备菜单又会通过兼容层读取旧 command 的 `isEnabled`，形成两套状态来源。

建议 hifi 显式发送完整 `availableActions`，宿主只消费公共字段和公共设备快照，并删除旧 command 状态读取。设备是否连接继续由 `AudioDeviceSelectionSnapshot` 表达；`.selectDevice` 表示当前是否允许切换设备。

按当前契约，显式列表必须包含 `.refresh`，否则宿主每秒状态刷新会被 `MediaPlaybackRequest.validate()` 拒绝。这虽然可行，但把后台轮询与用户动作放在同一可用性列表中语义不够理想：

- 本轮最小修复可以让 hifi 始终声明 `.refresh`。
- 后续可考虑规定 `.refresh` 是不受用户动作可用性限制的宿主同步操作。
- `.selectDevice` 仍应受动作可用性和单个设备连接状态共同约束。

无论采用显式模式还是缺省推导，都应只保留一个权威来源，并以契约测试锁定。

### 5.4 通用容器仍使用 SACD 专用呈现

位置：

- `foofoil/AppState/AppState+FileList.swift:801-839`
- `foofoil/ExtensionSupport/Presentation/ExtensionPlaybackSupport.swift:108-111`

容器投影条件已通用化为单资源且队列至少两项，但 `installContainerAudioList` 仍固定设置 `format: .sacd`，宿主项目 ID 也使用 `sacd:` 前缀。非 Hi-Fi 容器 Provider 会因此显示错误的 SACD 徽标和内部命名。

建议保持最小设计：

- 未知扩展容器先使用通用音频容器样式，不显示 SACD。
- 宿主生成的列表项目 ID 使用宿主命名空间，不编码具体扩展格式。
- 只有出现第二个真实容器类型、确认 UI 确实需要区分时，再在公共契约中增加最小显示语义。
- 不使用 `content.probe.reason` 私有字符串推导宿主 UI。

### 5.5 生命周期收尾

本项已提升为合并阻塞问题，完整范围、修复约束与测试见 §4.6。不能只改会话关闭方法。

### 5.6 `extensionItemID` 是否持久化应由 ID 生命周期决定

收尾阶段 2 已按阶段 0 决策处理：普通外部文件的 `extensionItemID` 改为会话内状态，不写入持久化；新会话清除旧盖章并重新映射；容器 `containerTrackID` 仍持久化用于恢复，重建时按新快照重新投影。恢复仍复用公共 `session.lifecycle` 的 `currentItemID`/position，由扩展解释不透明状态。下文为原始分析。

位置：

- `foofoil/FileList.swift:82-108`
- `foofoil/ExtensionSupport/Presentation/AppState+ExtensionQueue.swift:25-36`

`extensionItemID` 当前通过合成 `Codable` 写入文件列表状态。没有历史用户意味着可以直接改变当前存储格式，但不能忽略应用重启和当前版本内的恢复。

阶段 0 已确定最小恢复方案：复用公共 currentItemID，限定同 Provider/版本及未变化资源的原始请求顺序；外部文件盖章只作会话内缓存。具体编辑、恢复和测试约束以[阶段 0 决策记录](extension-boundary-closeout-stage0.zh-CN.md) §3–5 为准，阶段 2 落实代码；以下原则继续适用：

- 如果 ID 只在单个 Runtime session 内有效，将其改为仅内存态，并在新会话建立后重新盖章。
- 如果扩展契约保证 ID 在同一资源和当前扩展版本内稳定，可以持久化，但宿主只能等值比较，不解释格式。
- 容器曲目 ID 也不能未经契约保证就假定跨会话稳定；重建会话后优先重新投影容器列表。
- 单独定义恢复请求 `currentItemID` 的跨会话语义：明确由扩展保证同一资源内可恢复的标识，或由扩展解释不透明恢复状态并返回新映射。仅把 `extensionItemID` 改成内存态不解决恢复定位；先选定最小方案，再实施字段变化。
- 测试当前版本重启、新 Session UUID、临时 ID 改变、原曲目与位置恢复，以及资源被替换或曲目不存在时的明确降级。
- 如果未来需要真正的跨会话稳定资源标识，应新增专用、版本化字段，不复用临时队列 ID。

在当前没有明确稳定性保证的情况下，推荐将普通外部文件的 `extensionItemID` 设为会话内状态，并在重建时重新映射。无需为早期开发数据保留 track number 或旧 ID 回退。

## 6. 次要清理与工程质量

### 6.1 重复队列 ID 盖章

`AppState+ContentOpen.swift` 三条路径均在容器安装前后调用 `stampHostListWithExtensionQueueIDs`。容器安装本身已经为新项目写入扩展 ID，第二次全列表标准化和盖章在部分路径是重复工作。应在行为修复后，每条路径只保留语义必要的一次，并用测试确认列表发布次数。

### 6.2 无生产调用者兼容辅助方法

`HiFiLegacyAdapter.currentResource` 和 `currentURL` 当前没有生产调用者，但 `currentURL` 仍有测试调用，且内部调用 `currentResource`。迁移有价值的资源定位断言后，可随兼容层一起删除。

### 6.3 测试共享单例污染

部分测试把 Provider 注册到 `ExtensionHost.shared.resolver`。Swift Testing 可能并行执行，同进程共享注册表存在跨用例污染风险。优先让被测逻辑接受独立 `ProviderResolver` 或测试 Host；无法立即解耦时，至少将相关套件串行化并严格 defer 注销。

### 6.4 提交粒度

`9bb038b` 在阶段 5/6 的设备解耦和目录整理提交中，同时补入了 §19 PCM 连播、首次播放和 CUE 测试调整。相关连播基础来自更早的 `9c583f4`，但最终修复仍与结构整理混在同一提交中，增加审查和回退难度。后续应将行为修复、契约变更、目录移动和纯清理分开提交。

## 7. 验证要求

### 7.1 自动测试

| 场景 | 预期 |
| --- | --- |
| 非 Hi-Fi Provider 有 navigator contribution、无 actions capability | 不发送 `hifi.*`，返回不支持或保持会话 |
| 音频家族、有播放快照、无 `media.transport` | 不进入专用音频 UI，通用呈现也不显示可交互媒体控件 |
| `availableActions` 不含 seek | 不修改会话 position，不发送 seek |
| 当前队列 ID 无法映射且没有明确删除意图 | 保持原扩展队列 |
| 删除正在播放的曲目 | 按已定义编辑策略收尾/切换，不继续已删除后继 |
| 连续 seek、随后暂停/换会话、过期回包 | 旧回包或回滚不覆盖新状态 |
| 当前版本重启且临时项目 ID 改变 | 原曲目/位置按恢复契约还原并重新映射 |
| 用户删除或重排后继文件 | hifi `sequenceIDs` 和 `successors` 按宿主新顺序更新 |
| 单资源容器队列 | 宿主不按外部文件列表规则裁剪 |
| 非 Hi-Fi 多曲目容器 | 使用通用容器样式，不显示 SACD |
| P0 清理后的扩展菜单 | 不依赖 Hi-Fi 私有命令；标准媒体与设备操作仍可用 |
| 三种 PCM/扩展交接的关闭或释放失败 | 保留旧持有者/待释放记录，新 start 为零，有界重试或明确失败 |
| 释放中取消、新获取失败、不同设备/系统输出 | 资源归属清楚，无无关永久阻塞 |
| 至少 100 个音频文件连续扫描 | 不逐项 probe；另核查书签/文件 I/O，授权资源不误判 |
| 多 Provider 竞争、sniff 歧义、扫描取消 | 保留选择规则，取消后不发布过期结果 |
| 显式 `availableActions` | refresh、设备选择和播放控件状态与 Runtime 一致 |

### 7.2 三仓库命令

```sh
# extension-kit
swift test

# hifi
swift test
swift run hifi-runtime-smoke --self-test <当前 P1 fixture>

# foofoil
xcodebuild test -project foofoil.xcodeproj -scheme foofoil -destination 'platform=macOS'
./run
```

P0 fixture 删除后，应更新 smoke 参数和文档，只引用当前公共协议 fixture。

### 7.3 手动验证

- 普通 PCM 的系统输出和独占输出。
- 同一 DAC 的 PCM → DSD、DSD → PCM 和快速交替。
- DSF、DFF、SACD ISO 的播放、暂停、定位、切曲和后继播放。
- 宿主列表删除、裁剪和重排后的实际续播。
- 容器曲目激活与通用容器呈现。
- 设备拔出、重接、忙碌、切设备、关窗和退出后的资源释放。
- P0 清理后扩展菜单、媒体键和设备菜单的行为。
- PCM 连播和 CUE 首次播放修复后的真实音乐听感。

手动记录应包含 foofoil 与 hifi 提交号、设备型号或 UID、文件类型、采样率和实际操作结果。单一设备验证不能外推到未测采样率、多声道或其他硬件。

## 8. 建议实施顺序

按[收尾 checklist](extension-boundary-refactor-closeout-checklist.zh-CN.md)逐阶段执行；前一阶段任务和验收均完成后才进入下一阶段。已有工作先核验复用，不重复实施；遇到阻塞记录缺口，不能跳阶段宣称完成。

1. 收尾阶段 0：记录已关闭的 P0 支持决策、当前菜单依赖与三仓库基线；明确 ID 生命周期及当前版本恢复方案。
2. 收尾阶段 1：修导航泄漏、专用/通用 UI 能力门控和 seek 状态一致性。
3. 收尾阶段 2：落实 ID 映射/恢复并修队列投影，区分映射失败、删除当前曲与后继编辑。
4. 收尾阶段 3：贯通关闭、PCM/扩展暂停释放和协调器错误传播；故障注入与设备交接回归通过。
5. 收尾阶段 4：同步迁移 hifi 菜单、availableActions、设备状态及 Runtime 类型化执行，迁移行为测试后删除 P0 外部入口。
6. 收尾阶段 5：收紧连续扫描、授权与取消语义；处理通用容器呈现、重复盖章及遗留清理。
7. 收尾阶段 6：三仓库完整测试、当前公共协议 smoke、`./run` 和真实设备回归，汇总证据。

每阶段只运行与改动有关的检查，最终阶段做跨仓库集成。行为修复、契约变更与纯清理分开提交；新增硬件行为不能用上一版本的听音记录代替。用户已确认之前 PCM/CUE 问题解决，此结果作为当前基线，不代表后续收尾改动已通过实机验证。

## 9. 完成标准

满足以下条件后，可以将本轮扩展边界重构视为完成：

- 通用宿主路径不包含 Hi-Fi ID、私有命令解析或 `HiFiLegacyAdapter` 调用。
- hifi 对外只接受当前公共协议；内部执行不再以旧 `hifi.*` 协议字符串作为核心 dispatch。
- 非 Hi-Fi Provider 不可能收到任何 Hi-Fi 私有消息。
- 宿主只依据内容家族、已协商能力和公共快照决定呈现与操作。
- 专用音频 UI 和通用呈现都不会为无 `media.transport` 的会话显示可交互媒体控件。
- `availableActions` 在 UI、快捷操作和程序调用路径中被一致遵守。
- 队列映射失败不破坏扩展队列，外部文件和容器曲目的所有权边界有完整测试。
- 连续文件扫描不在主线程逐项执行 probe，并正确处理 security-scoped 资源。
- 关闭和设备释放失败可观察、可有界重试，保留旧持有者/待释放记录，且不会静默进入冲突的新独占会话。
- 通用容器不带 SACD 专用标识或 ID 命名。
- 不保留仅服务未发布 P0 的协议、fixture 和跨版本迁移；当前版本重启、恢复与资源生命周期保障及相应测试仍完整。
- extension-kit、hifi、foofoil 完整测试、Runtime smoke、应用启动和目标硬件回归通过，且无新增编译警告。

最终判断：当前代码已经形成正确的扩展边界骨架，剩余工作主要是消除仍被当前菜单间接使用的私有协议、收紧能力门控、保证队列和会话状态一致，并补齐 I/O 与设备释放失败路径。项目尚未发布，现在删除 P0 兼容和旧持久化假设的成本最低；完成上述修复后，重构才能真正从“结构已迁移”达到“通用生产路径无 Hi-Fi 特例”。
