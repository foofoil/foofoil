# foofoil 扩展职责收敛与主项目减负计划

日期：2026-09-09  
状态：实施中；阶段 0/1 的首批改动已落地，后续公共契约与跨仓库迁移尚未完成。  
范围：兄弟仓库 `foofoil`、`extension-kit`、`hifi`。本文中的源码路径均相对各自仓库根目录。

## 1. 问题与目标

目前已将 DSD 解析、DoP 和 HAL 播放引擎拆入 hifi，但宿主仍理解 Hi-Fi 的命令、曲目标识、会话恢复和设备服务。插件化隔离了底层实现，却未充分隔离功能编排。扩展基础设施增加后，宿主的维护负担仍然较大。

本轮目标是让宿主通过能力与数据契约使用音频扩展，减少修改 Hi-Fi 时必须同步修改的宿主模块。保留统一音频界面，收拢并下沉扩展专用逻辑。成功标准以职责、依赖和行为为主，不设必须削减多少行代码的指标。

源码规模基线（2026-09-09，统计对应源码目录中的 `.swift`，包含注释和空行，不含测试）：

| 部分 | 行数 |
| --- | ---: |
| foofoil/foofoil | 25,452 |
| 其中 AppState | 5,610 |
| 其中 ExtensionKit | 3,783 |
| extension-kit/Sources | 1,453 |
| hifi/Sources | 5,534 |

这些数值只描述源码规模，不能推导安装包、启动时间或内存开销；本轮不承诺性能收益。

## 2. 已确认的耦合位置

| foofoil 内的位置 | 当前问题 | 目标 |
| --- | --- | --- |
| `foofoil/ExtensionKit/ExtensionAudioModeView.swift` | UI 与控制器写死 `hifi.*`，监听设备并主动请求 Hi-Fi 状态 | 保留宿主 UI；通过通用操作与状态刷新入口驱动 |
| `foofoil/ExtensionKit/ExtensionPresentationView.swift` | 根据 `audio.hifi` 选择音频呈现，通用控件也发送 Hi-Fi 命令 | 根据内容家族、能力及会话数据选择呈现 |
| `foofoil/ExtensionKit/ExtensionHost.swift` | 固定 Hi-Fi 设备服务，通用关闭流程发送 `hifi.close` | 按能力解析服务；通用会话关闭与完成确认 |
| `foofoil/ExtensionKit/InProcessContentProvider.swift` | 将导航操作改写为 Hi-Fi 命令；内含 SACD ISO 魔数识别 | 传递通用导航操作；格式识别由扩展负责 |
| `foofoil/AppState/AppState+ContentOpen.swift` | 重建 Hi-Fi 历史、安装容器列表、拼装命令并协调设备切换 | 只编排宿主生命周期；扩展解释私有状态和容器曲目 |
| `foofoil/AppState/AppState+FileList.swift` | 直接识别 Hi-Fi 会话与队列标识 | 消费通用列表贡献与激活结果 |
| `foofoil/AppState/AppState+MediaType.swift` | 使用 Hi-Fi provider ID 判断音频行为 | 使用内容家族与已协商能力 |
| `foofoil/Views/NavigatorPanelView.swift` | 识别 `hifi.playback-queue` | 使用贡献的通用语义与选择状态 |
| `foofoil/AudioPlaybackController.swift` | 普通 PCM 控制器直接调用 Hi-Fi 设备服务 | 保留普通 PCM 播放，通过可选设备服务契约增强 |

此表是实施入口，不是完整迁移清单。阶段 0 必须补查关联调用者、持久化字段和测试。

## 3. 最终职责边界

| 职责 | foofoil | extension-kit | hifi |
| --- | --- | --- | --- |
| 窗口、快捷键、封面展示、媒体控件 | 实现统一 UI 与交互 | 必要的呈现数据 | 提供状态与元数据 |
| 文件权限、书签、历史数据库 | 管理授权与存储 | 资源及恢复请求契约 | 在授权资源范围内读取；解释私有恢复状态 |
| 宿主文件列表、循环/随机与跨窗口播放意图 | 管理宿主级用户策略 | 队列及操作语义 | 执行收到的播放序列；管理容器内部曲目 |
| SACD/DSF/DFF 识别与解析 | 调用内容匹配入口 | 最小匹配请求/结果契约 | 执行专用探测、解析、曲目定位 |
| 播放、暂停、定位、状态、关闭 | 发起通用操作并渲染结果 | 操作、能力、快照及错误语义 | 映射到音频引擎并返回结果 |
| 设备选择、独占与输出格式 | 提供通用菜单，协调宿主客户端意图 | 可选设备服务与生命周期契约 | 设备策略、租约、HAL/DoP 及硬件释放 |
| 普通 PCM 系统输出 | 保留原生播放路径与降级路径 | 必要的可选增强契约 | 提供已存在的设备增强服务 |
| 安装、加载、兼容性与 Registry | 实现宿主基础设施 | Manifest、ABI 与验证契约 | 发布扩展及兼容声明 |

跨仓库边界继续使用 C ABI 与 JSON 值消息，不传递 SwiftUI View、NSView、Swift 协议对象或 HAL 类型。UI 留在宿主不等于 UI 可以依赖具体插件命令。

本轮不新建仓库、不增加第三方依赖、不改为插件自带界面；不重写普通 PCM 引擎、窗口或历史数据库，也不顺带实现 DST、多声道硬件支持、Registry 安装或记住上次 DAC 等新功能。

## 4. 分阶段实施

### 阶段 0：建立行为和兼容基线

- [ ] 盘点 `audio.hifi`、`hifi.*`、`HiFi`、SACD 魔数及曲目 ID 解释逻辑，区分实现耦合、配置、文案和测试。
- [ ] 记录三个仓库的基线提交及工作区状态，列出可重复的测试命令和现有失败。
- [ ] 补齐历史状态、容器队列、命令和设备服务的代表性 JSON fixture；使用可分发的测试数据。
- [ ] 列出旧宿主/旧扩展实际要支持的版本组合，确定能力协商和兼容适配的退出条件。
- [ ] 在修改 HAL、DoP、SACD 打包或设备生命周期前，阅读 hifi 的 `docs/hifi-phase0-dsf-playback-handoff.md` 第 4 节。

验收：每个迁移点有明确的新归属、调用链和回归场景；硬件已验证与尚未验证的能力分开记录。

### 阶段 1：收拢 Hi-Fi 适配，保持现有行为

- [ ] 在宿主建立临时 `ExtensionSupport/Compatibility/HiFiLegacyAdapter.swift`，集中旧命令映射、旧 provider 判断和旧历史转换。按实际职责拆分必要文件，避免再形成巨型控制器。
- [ ] 从 AppState、导航视图和音频视图移出上述专用判断；宿主层仍掌握窗口、权限和用户意图。
- [x] 为通用关闭、导航和可选设备服务建立窄的宿主内部入口，先委托兼容适配执行。
- [x] 临时隔离 Provider 内的 SACD 探测；不因为移动目录就认定格式识别已经下沉。

验收：播放及恢复行为保持一致；旧命令不再散落于通用 UI/AppState。此阶段允许适配层仍有专用知识，但必须标注阶段 3–5 的替代路径。

### 阶段 2：补齐最小通用契约

优先复用 `ContentRequest`、`ContentSession`、`NavigatorAction`、播放快照与现有设备服务类型。检查 `stateReference` 的当前语义后再决定如何承载恢复状态，不直接改变其既有含义。

- [ ] 定义播放操作的稳定语义：播放、暂停、定位、上一项、下一项、状态读取、设备选择与关闭。字段名和消息封装在此阶段确定，不直接把 `hifi.` 改成另一个字符串前缀。
- [ ] 明确操作支持情况、禁用状态、错误结果、异步完成与关闭幂等性；关闭完成应表示文件/设备资源已经释放。
- [ ] 直接传递 `NavigatorAction`，明确列表所有权、稳定项目 ID、选择与排序反馈，避免宿主和扩展各维护一套互相冲突的队列。
- [ ] 定义版本化恢复请求：宿主持久化资源、授权和不透明扩展状态；扩展解释自己的曲目、位置等状态。
- [ ] 定义可选内容探测和设备服务的能力发现方式；复用现有协商机制，不增加无实际用途的注册框架。
- [ ] 明确状态刷新生命周期，优先沿用低频请求机制；不为消除 `hifi.status` 而引入新的常驻服务或全套事件总线。
- [ ] 增加契约、未知可选字段、缺失字段、能力缺失、版本不支持和消息校验测试。

验收：契约不依赖 Hi-Fi 命名或实现；最小非 Hi-Fi 测试 Provider 能表达相同操作。新增能力有明确版本与降级规则。

### 阶段 3：hifi 接管格式、导航与恢复语义

- [ ] hifi Runtime 接受新操作并映射到现有 Core；保留兼容窗口内的旧命令入口。
- [ ] 将 SACD 魔数识别迁至 hifi，宿主在权限和 I/O 预算内调用扩展探测；保留普通 ISO 不被误识别的测试。
- [ ] 将容器曲目解释、私有 ID、恢复位置和扩展内部列表操作迁至 Runtime/Core 的合适位置。
- [ ] 从宿主授权资源和扩展保存状态创建新会话，不复用已关闭 Session UUID；损坏、旧版或资源失效的状态必须可预测地降级。
- [ ] 提供可确认完成的关闭与设备释放结果；复用现有播放引擎，避免同时改动底层音频算法。
- [ ] 因 hifi 当前手写 JSON 且未直接依赖 extension-kit，验证 Runtime 实际消息与契约 fixture 一致，不能只测试 Swift 类型的自洽性。

验收：通过 Runtime 消息测试可独立完成容器曲目选择、播放定位、恢复和关闭；宿主不需要解释 SACD 布局或 Hi-Fi 私有状态。

### 阶段 4：宿主切换到通用会话与呈现

- [ ] `ExtensionAudioModeView` 继续复用宿主音频 UI，依据内容家族与能力呈现，通过通用媒体操作驱动。
- [ ] AppState 只负责会话创建/替换/关闭、用户意图、授权、存储和宿主文件队列；删除 Hi-Fi 恢复步骤和字符串命令判断。
- [ ] 列表与导航按通用贡献 ID 传递操作，不解释 ID 的前缀或具体值。
- [ ] 明确单一状态来源：扩展确认播放状态，宿主保存交互状态；防止旧会话异步结果覆盖新会话、重复自动续播或重复释放。
- [ ] 将通用关闭路径切换为生命周期操作；旧扩展只通过显式兼容适配进入旧路径。

验收：非 Hi-Fi 测试 Provider 可以复用音频控件、导航、恢复和关闭流程；禁用或移除 hifi 后，普通内容功能仍可用。

### 阶段 5：解耦可选设备服务

- [ ] 将 `performHiFiDeviceCommand`、固定扩展 ID 查找替换为已协商的设备服务入口；服务不可用时保留普通 PCM 系统输出。
- [ ] hifi 管理设备 UID、独占租约、格式变更及恢复；宿主只协调跨窗口意图和客户端生命周期。
- [ ] 明确同设备 PCM/DSD 交接顺序：原持有者释放完成后新持有者再获取；快速切换、失败与取消均不能残留租约。
- [ ] 系统默认播放继续排除在现有独占仲裁之外；不改变现有 DSD DoP-only 策略，不增加 DSD→PCM 静默回退。
- [ ] 确认设备监听的唯一职责来源，移除 UI 中重复的 Hi-Fi 专用监听；宿主自身确有需要的系统设备监听可以保留。

验收：完成真实 DAC 回归后才标记设备解耦完成；没有硬件时记录未验证项目，不以单元测试替代硬件结论。

### 阶段 6：清理结构与兼容代码

- [ ] 将宿主 `foofoil/ExtensionKit/` 最终整理为 `foofoil/ExtensionSupport/`，按实际需要分为 Runtime、Management、Presentation、Compatibility。
- [ ] 保留现有 `foofoil/Extensions/` 语言/系统类型扩展目录，避免名称混淆；独立 `extension-kit` 仓库名称不变。
- [ ] 视图与播放控制适配器分文件；不把宿主加载器、UI 或 Registry 移入契约包。
- [ ] 达到阶段 0 定义的支持版本退出条件后删除 Hi-Fi 旧命令适配；若仍需支持旧版，明确保留范围与删除条件。
- [ ] 更新 Xcode 引用、README、AGENTS 和开发说明，记录新职责与验证结果。

验收：通用生产路径不包含 Hi-Fi 特例；允许的扩展标识仅存在于安装/偏好配置、明确隔离的旧版兼容代码、文案和测试中。

## 5. 兼容、提交顺序与回退

按“契约 → hifi 支持新协议并保留旧入口 → 宿主消费新能力 → 清理”的顺序发布。各阶段拆成可独立审查和验证的小提交，目录移动与行为修改分开。

| 组合 | 预期 |
| --- | --- |
| 旧宿主 + 新 hifi | 在声明支持的范围内仍接受旧消息 |
| 新宿主 + 旧 hifi | 按协商结果进入隔离适配；不支持的能力禁用或明确报不兼容 |
| 新宿主 + 新 hifi | 使用通用协议，不经过旧命令映射 |
| 新宿主 + 无 hifi | 普通 PCM 和其他内置内容正常工作 |

新增 Codable 字段须可兼容缺失值；不能假定未知枚举值天然兼容。C ABI 如需扩展，只追加并检查结构大小与函数指针。只有实际兼容的版本才能声明连续 API 范围。

历史迁移保留旧记录读取路径，不做破坏性批量覆盖。失败时允许重新打开资源或说明不可恢复原因。回退以已验证的跨仓库版本组合为单位；在删除旧协议入口前确认旧宿主支持要求已经解除。

## 6. 验证与完成标准

每阶段执行与变更相关的测试；改变契约运行 extension-kit 的 `swift test`，改变 hifi Runtime/Core 运行 hifi 的 `swift test` 并验证实际 Runtime 消息。宿主行为变更运行相关测试及构建，阶段集成时执行：

```sh
# 在 foofoil 仓库根目录
xcodebuild test -project foofoil.xcodeproj -scheme foofoil -destination 'platform=macOS'
./run
```

`./run` 用于构建、注入开发插件并启动，不以 Xcode ⌘R 替代插件联调。文档单独修改无需启动应用。

必要回归场景：

| 范围 | 场景 |
| --- | --- |
| 通用性 | 用不同 provider ID、不同私有命令与不透明曲目 ID 的测试 Provider 完成播放、列表、恢复和关闭 |
| 普通内容 | 无/禁用 hifi 时的 MP3/AAC、文件打开、列表、窗口与历史 |
| 音频呈现 | 播放/暂停/定位、上一首下一首、循环/随机、封面、快捷键、系统媒体键及中英文本地化 |
| DSD 与容器 | DSF/DFF、未压缩立体声 SACD ISO，曲目选择、定位和两轨自动续播；普通 ISO 不被误接管 |
| 恢复 | 老历史记录、新记录、曲目或文件失效、状态损坏、恢复时不应自动播放的用户意图 |
| 并发与生命周期 | 快速换文件、关窗、切设备、退出、过期状态回包，确保无重复续播和资源遗留 |
| 硬件 | 已验证范围内的 DSD64/128/256、设备拔出/忙碌/hog/睡眠恢复、同 DAC PCM/DSD 交接、系统默认输出 |

收尾同时满足：

- [ ] 上表的耦合点已迁移或有明确、有限的兼容例外。
- [ ] 通用路径无需增加 Hi-Fi 判断即可支持第二个测试音频 Provider。
- [ ] 不把复杂度转移为新的巨型适配器，也不把实现代码塞进 extension-kit。
- [ ] 旧历史与声明支持的协议组合通过验证，无新增编译警告。
- [ ] 记录硬件实际验证范围，明确未验证项目；未通过的必要场景不能标为完成。
- [ ] 重统计源码分布、残留专用调用点及涉及模块，说明真实变化，不把文件移动当作代码减负成果。

## 7. 风险与实施决策点

最大的风险是队列所有权、恢复兼容和设备释放时序。阶段 2 先用消息示例固定语义，再改调用链；阶段 3–5 分开推进，避免恢复、呈现和硬件仲裁同时重写。

待阶段 0–2 确定：实际旧版支持范围、`stateReference` 与现有存储如何衔接、内容探测消息形态、多个设备服务的选择规则。遵循现有能力协商和偏好解析机制，只扩展当前需求确实缺失的部分。

本轮聚焦扩展边界。`FloatingWindowController` 等大型文件可能仍有独立维护问题，应另行评估；完成本计划不等于主项目所有复杂度都已消除。

## 8. 实施记录：2026-09-09，首批兼容层收拢

基线提交：foofoil `aa10d11ed992998c4b5fd149184982a8f844889e`，extension-kit `d8b134c484b5301bc13f67c8d6c147025270384f`，hifi `af107d55f490c699518b962f566c6490f49fc1bf`。开始实施时三仓库业务代码干净，foofoil 仅有本计划文档未跟踪。

本批仅修改宿主，不改变 ABI、JSON 消息值、历史存储格式或 hifi 引擎。新增 `foofoil/ExtensionSupport/Compatibility/`，按职责分文件：

- `HiFiLegacyAdapter.swift`：旧 provider/队列标识、命令编码、设备命令解析和源文件定位；合并原来两处重复的 `file:` 曲目 ID 解析。
- `HiFiLegacyAdapter+Restoration.swift`：历史恢复算法，保留先选曲后定位、位置校验、暂停恢复和 provider 变化时跳过恢复的语义。
- `HiFiLegacyAdapter+Navigation.swift`：导航操作到旧命令与快照的转换。
- `HiFiLegacyAdapter+ContentProbe.swift`：现有 SACD 主 TOC 魔数探测，后续阶段 3 下沉到 hifi。
- `AppState+HiFiLegacyQueue.swift`：宿主文件列表与旧 Hi-Fi 队列的桥接。仍是宿主 AppState 扩展，不宣称已将队列实现迁出宿主。

新增宿主内部 `ExtensionMediaAction`，让音频界面发送播放、暂停、上一项、下一项、刷新和设备选择意图。当前仍由旧适配器编码，不能当作阶段 2 的公共协议或第二个音频 Provider 已可直接复用的证明。

`AppState+ContentOpen.swift` 从 1,309 行减到 1,186 行，`AppState+FileList.swift` 从 1,051 行减到 1,004 行，`InProcessContentProvider.swift` 从 127 行减到 69 行。主要收益是归属集中和消除重复解析；多数代码仍留在同一宿主 target，本批不宣称宿主总量或运行开销下降。

保留的后续工作：设备服务仍固定到 Hi-Fi，独占交接仍在宿主命令路径，界面仍调用显式兼容判断，部分容器展开逻辑仍在 FileList。阶段 0 的完整版本矩阵与跨仓库 JSON fixture、阶段 1 的全部解耦均未标为完成。下一批优先收拢关闭/恢复调用入口与设备服务适配，再推进公共契约；兼容代码退出条件是声明支持的旧版组合完成验证并不再需要旧协议。

本批验证：

- 修改前、修改后均执行 `xcodebuild test -project foofoil.xcodeproj -scheme foofoil -destination 'platform=macOS' -only-testing:foofoilTests`，结果通过。
- 修改后 xcresult 汇总：195 项测试通过、1 项跳过、0 项失败；展开参数化测试后为 206 次通过。跳过的是 `CueSheetTests/exclusivePlaybackSurvivesTrackChangesAndPause()`。
- 新增 `HiFiLegacyAdapterTests`：覆盖裁剪队列后的资源定位、非法资源 ID、容器曲目、导航快照转换与原值保留、缺失贡献、恢复到其他 Provider 及 SACD 魔数位置/扩展名校验。原有历史恢复测试改为直接测试适配器，保留原断言。
- 无新增源码编译警告；日志中的 Selector/未使用变量警告及 AppIntents 元数据提示在基线中已存在。
- `./run` 成功构建、注入并签名 Hi-Fi 开发插件后启动应用；本批未执行真实 DAC 听音、设备切换或 UI 手动回归，不将启动成功视为硬件验证。
- 本地日志：`/tmp/foofoil-extension-baseline.log`、`/tmp/foofoil-extension-refactor-tests.log`、`/tmp/foofoil-extension-refactor-run.log`，均未纳入仓库。

## 9. 实施记录：2026-09-09，关闭、恢复与设备服务入口

基于 foofoil `c494c12` 继续实施。本批仍只修改宿主内部接口，未修改 extension-kit、hifi、公开 ABI、JSON 格式或历史存储。

本批变更：

- `ContentProvider` 增加 `closeSession` 和 `restorePlayback`。默认关闭为空操作，默认恢复保留新会话；通用 Host 不再向所有 Provider 发送 `hifi.close`。进程内 Hi-Fi Provider 委托兼容层发送原关闭消息并等待完成，其他 Provider 不会误收 Hi-Fi 私有关闭命令。Host 继续等待异步关闭，对失败记录日志；本批未将其改为向上抛错的 API。
- `ExtensionHost.restorePlayback` 按新会话 Provider 路由恢复，Provider 改变时跳过旧状态；AppState 保留授权、生命周期、过期结果保护、失败关闭和存储职责，不再拼装恢复曲目与定位命令。
- 将命令及导航的校验入口收拢到 `ContentProvider` 的宿主扩展中。Hi-Fi 恢复的每个中间快照仍执行原有校验，恢复结果也由 Host 校验，避免抽取调用链时丢失校验。
- 新增 `ExtensionAudioDeviceServicing` 内部接口和 `HiFiLegacyAudioDeviceService` 适配。普通 PCM 控制器改为调用 `isAudioDeviceServiceAvailable` / `performAudioDeviceCommand`。固定 Hi-Fi Runtime 的选择和离开主线程的调用保留在兼容层，请求、返回快照及 Runtime 错误原样传递。
- 删除无调用者的 `releaseHiFiPCMOutputAndWait`；实际退出仍走既有 Runtime shutdown。设备服务缺失时通用入口返回已有的 `unsupportedRequest` 错误，不再暴露固定 Hi-Fi ID；普通 PCM 的可用性检查和系统输出路径保留。

本批新增回归覆盖：默认 Provider 无私有关闭命令、非 Hi-Fi Provider 的自定义恢复、切换 Provider 跳过恢复、无效恢复结果拒绝、旧 Hi-Fi 关闭完成等待、激活结果无效时不继续 seek，以及设备服务的参数、线程和错误传递。原有延迟关闭测试改为实现 Provider 的关闭入口，继续验证宿主的等待顺序。

阶段边界：这是宿主内部适配收拢，不代表已经实现公共关闭/恢复消息或按能力发现多个设备服务。下一步进入阶段 2 的最小契约设计与 fixture，随后让 hifi 接收通用消息；独占交接、部分 AppState/导航兼容判断、容器展开仍待迁移。

本批验证：

- `xcodebuild test -project foofoil.xcodeproj -scheme foofoil -destination 'platform=macOS' -only-testing:foofoilTests` 通过；xcresult 汇总 202 项通过、1 项硬件测试跳过、0 项失败，展开参数化测试后为 215 次通过。
- `./run` 成功构建、注入并签名 Hi-Fi 开发插件，应用进程已启动。未进行真实 DAC 播放、切换设备或听音回归。
- `git diff --check` 通过；未引入新的编译警告。未修改 hifi 或 extension-kit，因此未重复运行两者的独立测试。
- 本地日志：`/tmp/foofoil-extension-lifecycle-tests.log`、`/tmp/foofoil-extension-lifecycle-run.log`，未纳入仓库。
