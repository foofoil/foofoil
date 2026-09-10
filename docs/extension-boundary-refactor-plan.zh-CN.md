# foofoil 扩展职责收敛与主项目减负计划

日期：2026-09-09  
状态：阶段 0–5 已完成；2026-09-10 用户确认阶段 5 手动实机回归通过。阶段 6 已完成结构清理与验证；旧版支持窗口保持开放，有限适配按退出条件保留。

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

此表是实施入口。阶段 0 已补查关联调用者、持久化字段和测试，完整清单见第 12.1 节。

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

勾选表示整条任务已完成；部分完成项保留未勾选并注明剩余工作。依据第 8–18 节实施记录核对，阶段验收与真实硬件验证单独判断。

### 阶段 0：建立行为和兼容基线

- [x] 盘点 `audio.hifi`、`hifi.*`、`HiFi`、SACD 魔数及曲目 ID 解释逻辑，区分实现耦合、配置、文案和测试。
- [x] 记录三个仓库的基线提交及工作区状态，列出可重复的测试命令和现有失败。
- [x] 补齐历史状态、容器队列、命令和设备服务的代表性 JSON fixture；使用可分发的测试数据。
- [x] 列出旧宿主/旧扩展实际要支持的版本组合，确定能力协商和兼容适配的退出条件。
- [x] 在修改 HAL、DoP、SACD 打包或设备生命周期前，阅读 hifi 的 `docs/hifi-phase0-dsf-playback-handoff.md` 第 4 节。

验收：每个迁移点有明确的新归属、调用链和回归场景；硬件已验证与尚未验证的能力分开记录。详见第 12 节。

### 阶段 1：收拢 Hi-Fi 适配，保持现有行为

- [x] 在宿主建立临时 `ExtensionSupport/Compatibility/HiFiLegacyAdapter.swift`，集中旧命令映射、旧 provider 判断和旧历史转换。按实际职责拆分必要文件，避免再形成巨型控制器。
- [x] 从 AppState、导航视图和音频视图移出上述专用判断；宿主层仍掌握窗口、权限和用户意图。
- [x] 为通用关闭、导航和可选设备服务建立窄的宿主内部入口，先委托兼容适配执行。
- [x] 临时隔离 Provider 内的 SACD 探测；不因为移动目录就认定格式识别已经下沉。

验收：播放及恢复行为保持一致；旧命令不再散落于通用 UI/AppState。此阶段允许适配层仍有专用知识，但必须标注阶段 3–5 的替代路径。

### 阶段 2：补齐最小通用契约

优先复用 `ContentRequest`、`ContentSession`、`NavigatorAction`、播放快照与现有设备服务类型。检查 `stateReference` 的当前语义后再决定如何承载恢复状态，不直接改变其既有含义。

- [x] 定义播放操作的稳定语义：播放、暂停、定位、上一项、下一项、状态读取、设备选择与关闭。字段名和消息封装在此阶段确定，不直接把 `hifi.` 改成另一个字符串前缀。
- [x] 明确操作支持情况、禁用状态、错误结果、异步完成与关闭幂等性；关闭完成应表示文件/设备资源已经释放。
- [x] 直接传递 `NavigatorAction`，明确列表所有权、稳定项目 ID、选择与排序反馈，避免宿主和扩展各维护一套互相冲突的队列。
- [x] 定义版本化恢复请求：宿主持久化资源、授权和不透明扩展状态；扩展解释自己的曲目、位置等状态。
- [x] 定义可选内容探测和设备服务的能力发现方式；复用现有协商机制，不增加无实际用途的注册框架。
- [x] 明确状态刷新生命周期，优先沿用低频请求机制；不为消除 `hifi.status` 而引入新的常驻服务或全套事件总线。
- [x] 增加契约、未知可选字段、缺失字段、能力缺失、版本不支持和消息校验测试。

验收：契约不依赖 Hi-Fi 命名或实现；最小非 Hi-Fi 测试 Provider 能表达相同操作。新增能力有明确版本与降级规则。

### 阶段 3：hifi 接管格式、导航与恢复语义

- [x] hifi Runtime 接受新操作并映射到现有 Core；保留兼容窗口内的旧命令入口。
- [x] 将 SACD 魔数识别迁至 hifi，宿主在权限和 I/O 预算内调用扩展探测；保留普通 ISO 不被误识别的测试。
- [x] 将容器曲目解释、私有 ID、恢复位置和扩展内部列表操作迁至 Runtime/Core 的合适位置。
- [x] 从宿主授权资源和扩展保存状态创建新会话，不复用已关闭 Session UUID；损坏、旧版或资源失效的状态必须可预测地降级。
- [x] 提供可确认完成的关闭与设备释放结果；复用现有播放引擎，避免同时改动底层音频算法。
- [x] 因 hifi 当前手写 JSON 且未直接依赖 extension-kit，验证 Runtime 实际消息与契约 fixture 一致，不能只测试 Swift 类型的自洽性。

验收：通过 Runtime 消息测试可独立完成容器曲目选择、播放定位、恢复和关闭；宿主不需要解释 SACD 布局或 Hi-Fi 私有状态。

### 阶段 4：宿主切换到通用会话与呈现

- [x] `ExtensionAudioModeView` 继续复用宿主音频 UI，依据内容家族与能力呈现，通过通用媒体操作驱动。
- [x] AppState 只负责会话创建/替换/关闭、用户意图、授权、存储和宿主文件队列；删除 Hi-Fi 恢复步骤和字符串命令判断。
- [x] 列表与导航按通用贡献 ID 传递操作，不解释 ID 的前缀或具体值。
- [x] 明确单一状态来源：扩展确认播放状态，宿主保存交互状态；防止旧会话异步结果覆盖新会话、重复自动续播或重复释放。
- [x] 将通用关闭路径切换为生命周期操作；旧扩展只通过显式兼容适配进入旧路径。

验收：非 Hi-Fi 测试 Provider 可以复用音频控件、导航、恢复和关闭流程；禁用或移除 hifi 后，普通内容功能仍可用。

### 阶段 5：解耦可选设备服务

- [x] 将 `performHiFiDeviceCommand`、固定扩展 ID 查找替换为已协商的设备服务入口；服务不可用时保留普通 PCM 系统输出。
- [x] hifi 管理设备 UID、独占租约、格式变更及恢复；宿主只协调跨窗口意图和客户端生命周期。
- [x] 明确同设备 PCM/DSD 交接顺序：原持有者释放完成后新持有者再获取；快速切换、失败与取消均不能残留租约。（代码与自动测试验证顺序；2026-09-10 用户确认同 DAC 手动回归通过，见第 17 节补验。）
- [x] 系统默认播放继续排除在现有独占仲裁之外；不改变现有 DSD DoP-only 策略，不增加 DSD→PCM 静默回退。
- [x] 确认设备监听的唯一职责来源，移除 UI 中重复的 Hi-Fi 专用监听；宿主自身确有需要的系统设备监听可以保留。

验收：完成真实 DAC 回归后才标记设备解耦完成；没有硬件时记录未验证项目，不以单元测试替代硬件结论。

### 阶段 6：清理结构与兼容代码

- [x] 将宿主 `foofoil/ExtensionKit/` 最终整理为 `foofoil/ExtensionSupport/`，按实际需要分为 Runtime、Management、Presentation、Compatibility。
- [x] 保留现有 `foofoil/Extensions/` 语言/系统类型扩展目录，避免名称混淆；独立 `extension-kit` 仓库名称不变。
- [x] 视图与播放控制适配器分文件；不把宿主加载器、UI 或 Registry 移入契约包。
- [x] 达到阶段 0 定义的支持版本退出条件后删除 Hi-Fi 旧命令适配；若仍需支持旧版，明确保留范围与删除条件。
- [x] 更新 Xcode 引用、README、AGENTS 和开发说明，记录新职责与验证结果。

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

- [x] 上表的耦合点已迁移或有明确、有限的兼容例外。
- [x] 通用路径无需增加 Hi-Fi 判断即可支持第二个测试音频 Provider。
- [x] 不把复杂度转移为新的巨型适配器，也不把实现代码塞进 extension-kit。
- [x] 旧历史与声明支持的协议组合通过验证，无新增编译警告。
- [x] 记录硬件实际验证范围，明确未验证项目；未通过的必要场景不能标为完成。
- [x] 重统计源码分布、残留专用调用点及涉及模块，说明真实变化，不把文件移动当作代码减负成果。

## 7. 风险与实施决策点

最大的风险是队列所有权、恢复兼容和设备释放时序。阶段 2 先用消息示例固定语义，再改调用链；阶段 3–5 分开推进，避免恢复、呈现和硬件仲裁同时重写。

阶段 0 已确定实际旧版支持范围与兼容适配退出条件（第 12.2 节）。阶段 2 已确定：`stateReference` 继续只作存储键；内容探测为 `content.probe` v1 application 能力；多个设备服务按 audio 域偏好，否则唯一候选，否则不用。遵循现有能力协商和偏好解析机制，只扩展当前需求确实缺失的部分。

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

## 10. 实施记录：2026-09-09，首个跨仓库生命周期契约

本批基于 foofoil `8fe1541`、extension-kit `d8b134c`、hifi `af107d5`，打通 `close` / `restore`，未将播放操作、导航操作和设备服务一次性改写。

### 已实现

- extension-kit 新增 `session.lifecycle` v1 能力、`SessionLifecycleRequest`、`PlaybackRestorationState`、验证与共享 JSON fixture。消息复用 `perform_command`，不扩展 C ABI 函数表，也不改变原会话快照和历史存储格式。
- hifi 声明并激活该能力，接受通用关闭/恢复消息。恢复的曲目 ID 解释、暂停、选曲和位置限制在 Runtime 内执行，宿主不再为新插件逐步发送 Hi-Fi 激活与 seek 命令。
- 新宿主按新会话能力选择协议；无能力声明或版本不支持时保留旧 Hi-Fi 适配。旧命令入口仍保留，新插件可继续接受旧宿主的原命令。
- 通用关闭可重复调用；关闭成功后运行时记录已移除。释放失败会返回错误并保留可重试记录，不再先删除记录后忽略 stop 错误。宿主关闭失败目前仍记录日志，自动重试和向上抛错不在本批范围。
- 正常恢复保持暂停，不获取输出设备；正在播放的会话拒绝恢复。旧曲目消失时不套用其位置；合法位置按新曲目长度及 DSD 定位粒度限制。损坏的历史位置由宿主省略，在线非法消息仍拒绝。

完整协议说明在兄弟仓库 `extension-kit/docs/session-lifecycle-v1.zh-CN.md`。`stateReference` 的含义保留；本版只传通用曲目 ID 和位置，不定义私有恢复 blob。

### 验证与兼容范围

- extension-kit `swift test`：13 项测试通过，覆盖共享 fixture、版本/能力状态、非法参数、未知字段及未知操作。
- hifi `swift test`：36 项测试通过。
- hifi `swift run hifi-runtime-smoke --self-test ../extension-kit/Sources/FoofoilExtensionKit/Fixtures/SessionLifecycleRequests.json`：使用同一 fixture 经真实 C ABI 验证新协议，同时执行旧导航/定位命令；覆盖恢复位置、缺失曲目、时长限制、非法消息拒绝、重复关闭及运行时记录释放。测试不播放合成 DSF。
- 宿主单元测试：205 项通过、1 项硬件测试跳过、0 项失败；展开参数化测试后为 220 次通过。新增通用 Provider ID、旧插件能力缺失、未知契约版本、新会话 UUID 和损坏历史位置的请求构造回归。
- 这些测试证明消息格式互通和旧命令继续可用，不等同于所有已发布宿主/插件二进制组合的完整验证。完整版本矩阵仍是阶段 0 的后续事项。
- `./run` 已成功重建应用和新版 Hi-Fi 插件、签名注入并启动应用。仓库内未找到真实 DSF/DFF 听音文件，本批未执行真实 DAC 回归；合成 fixture 不能替代听音验证。
- 无新增编译警告；三仓库 `git diff --check` 通过。日志分别为 `/tmp/foofoil-kit-lifecycle-contract.log`、`/tmp/foofoil-hifi-lifecycle-contract.log`、`/tmp/foofoil-hifi-lifecycle-abi.log`、`/tmp/foofoil-host-lifecycle-contract.log`、`/tmp/foofoil-session-lifecycle-run.log`。

### 剩余工作

下一批优先迁移通用媒体控制与导航请求，移除宿主命令路径对 Hi-Fi 播放/暂停/设备命令的解释；随后迁移内容探测、可选设备服务能力发现与目录清理。当前兼容层仍须保留，新生命周期契约并不意味着整个阶段 2/3 已完成。

## 11. 实施记录：2026-09-09，媒体控制与导航动作公共契约

本批基于 foofoil `0218453`、extension-kit `20b9bc8`、hifi `37c9db6`。

### 已实现

- extension-kit 新增 `media.transport` v1 和 `ui.navigator-actions` v1，分别承载 `MediaPlaybackAction` 与已有 `NavigatorAction`；继续复用 ABI v1 `perform_command`。完整消息说明为兄弟仓库 `extension-kit/docs/media-navigation-v1.zh-CN.md`。
- 媒体动作覆盖 play、pause、refresh、previous、next、seek、selectDevice。宿主界面直接使用公共动作，Provider 按能力发送新消息；旧 Hi-Fi 在适配层编码为原命令。无能力的新协议不试发，实际新协议调用失败不自动重放旧命令。
- AppState 的执行流程按动作识别暂停、起播、设备切换和状态检查点，不再解析 hifi.play/pause/status/device 字符串。旧菜单贡献的私有命令只在兼容入口翻译；其他扩展的自定义命令保留原通道。保持现有代次检查、五秒状态保存节流和独占交接顺序。
- hifi 接收通用导航动作，并根据 Runtime 真实曲目列表再次验证项目、贡献、移动目标和操作权限。宿主不再为新插件改写导航快照后发送 Hi-Fi 命令；SACD 队列仍禁止排序，Hi-Fi 仍不支持删除曲目。
- 修正公共历史恢复的边界问题：从曲目末尾恢复到另一曲时，显式禁止切曲逻辑自动起播。普通导航和自然续播继续沿用原有播放意图。

### 验证

- extension-kit `swift test`：18 项通过。新增请求编码/解码、能力/版本、非法定位参数、通用不透明贡献/项目 ID 测试。
- hifi `swift test`：39 项通过。新增 Runtime 消息测试 target，验证多项目移动保持原顺序、容器禁止移动、无效/重复/自目标项目及错误媒体参数拒绝。
- 宿主单元测试：207 项通过、1 项硬件测试跳过、0 项失败；展开参数化测试后 222 次通过。新增通用 Provider 收到类型化动作而非私有字符串、旧定位快照兼容与非法动作在分发前被拒绝的测试。
- 共享 `MediaNavigationRequests.json` 与已有生命周期 fixture 经真实 C ABI 验证暂停、定位、刷新、前后切曲、选曲、排序、非法请求拒绝，以及关闭/恢复兼容。恢复到另一曲保持暂停的边界回归通过。
- smoke 未执行合成音频起播或真实 DAC 选择；play 和设备切换的硬件行为未在本批实测。
- `./run` 已成功重建应用和 Hi-Fi 开发插件、签名注入并启动应用；三仓库 `git diff --check` 通过，无新增编译警告。
- 本地日志：`/tmp/foofoil-kit-media-contract.log`、`/tmp/foofoil-hifi-media-contract.log`、`/tmp/foofoil-host-media-tests.log`、`/tmp/foofoil-media-navigation-abi.log`、`/tmp/foofoil-media-navigation-run.log`，均未纳入仓库。

### 剩余边界

独占仲裁仍只针对既有 Hi-Fi 输出；`media.transport` 能力不等于要求独占设备。本批没有把其他 Provider 自动加入硬件抢占。设备服务发现、格式探测、宿主列表映射和视图中的兼容判断继续按后续阶段迁移。菜单旧命令和兼容适配仍保留，总代码行数减少不是本批完成标准。

## 12. 实施记录：2026-09-09，阶段 0 行为与兼容基线

本批补齐阶段 0 未完成项：设备服务/历史/容器/旧命令 fixture、版本组合与退出条件、迁移点归属与硬件记录。不重做第 8–11 节已落地的关闭、恢复、媒体和导航契约。未修改 HAL、DoP、SACD 打包或设备生命周期算法。

基线提交（开始本批时，工作区干净）：foofoil `97fe2e7`，extension-kit `f46f091`，hifi `57a65b5`。产品版本：foofoil `MARKETING_VERSION = 1.0`，hifi Manifest `0.1.0`，Extension API 仅 v1。三仓库均无发布 tag。

### 12.1 迁移点：新归属、调用链、回归场景

实现耦合（必须迁移或隔离到兼容层）：

| 位置 | 现状 | 新归属 | 调用链 | 回归场景 |
| --- | --- | --- | --- | --- |
| `ExtensionAudioModeView` | 按内容家族/`media.transport` 进入；通用媒体动作驱动 | 宿主 UI；按内容家族与能力刷新 | 控件 → `performExtensionMediaAction` → Provider（新协议或适配层） | 播放/暂停/定位/上一项下一项、封面、设备菜单启用、失败文案 |
| `ExtensionPresentationView` | `mediaPlayback` + 音频家族或 `media.transport` 进入音频 UI | 按 `contentFamily` 与会话能力选择呈现 | `extensionSession` → 音频或通用呈现 | Hi-Fi 与通用音频走音频 UI；无播放快照不误入；无 hifi 时普通音频仍可用 |
| `ExtensionHost` | 关闭/恢复已按 Provider 路由；设备服务按 `audio.device-selection` 发现，无声明则不用 | 按已协商能力解析服务 | PCM 控制器 → `performAudioDeviceCommand` → 能力选中的 Runtime | 关闭等待完成；非 Hi-Fi 不收 `hifi.close`；设备服务缺失时系统输出 |
| `InProcessContentProvider` | 导航改写为旧命令；已声明 `content.probe` 时调用扩展嗅探 | 通用 `NavigatorAction`；探测下沉 hifi | 打开 `.iso` → `content.probe`；无能力时 P0 魔数 | 普通 ISO 不接管；SACD 接管；activate/move |
| `AppState+ContentOpen` | 连续 DSD 序列、独占交接、部分 `supports` 判断 | 宿主生命周期与跨窗口意图 | 打开/切曲 → Host.open → 关闭等待 → 新会话 | 打开 DSF、暂停恢复、快切文件、PCM/DSD 交接 |
| `AppState+FileList` | 追加 ISO 时仍开临时会话取曲目队列（probe v1 不含曲目列表） | 探测只负责匹配 | 追加 URL → 匹配 → 会话 → `installContainerAudioList` | ISO 展开曲目；与普通音频混合成分区 |
| `AppState+MediaType` | `isAudioDocument` / `currentAudioPresentationURL` 走音频 chrome 与列表类型 | 内容家族与列表类型 | 呈现层读当前 URL | 容器与外部文件封面路径正确 |
| `NavigatorPanelView` | 会话播放贡献 ID 或宿主音视频列表显示正在播放图标 | 贡献的通用播放语义 | 贡献 ID/选择状态 → 波形图标 | 宿主列表与扩展队列当前项指示 |
| `AudioPlaybackController` | 已走窄设备服务入口；无能力声明时系统 PCM | 已协商的可选设备服务 | play/stop → snapshot/prepare/release | 独占 PCM、系统默认回退、停止释放租约 |
| `AppState+HiFiLegacyQueue` | 不透明 ID 盖章与 1:1 资源对应；不再解析 `file:` / 曲目序号 | 扩展解释私有 ID | 列表选择 → 通用 activate | 容器切曲、文件队列裁剪后资源仍指向原文件 |
| `HiFiLegacyAdapter+ContentProbe` | 仅未声明 `content.probe` 的旧 Hi-Fi 读主 TOC | hifi `content.probe` | 打开 `.iso` → 探测 | 普通 ISO 拒绝；SACD 主 TOC 接受 |

配置（允许保留 Hi-Fi 标识）：`hifi/ExtensionManifest.json` 的 `audio.hifi`、安装/偏好中的扩展 ID、`UserDefaults` 键 `app.foofoil.extension.hifi.preferred-pcm-device-uid`（扩展私有）。

文案：本地化键如 “Hi-Fi Playback Failed”“Hi-Fi Output Device”；不作为协议。

测试：允许继续出现 `audio.hifi`、`hifi.*` 和 SACD fixture。

持久化字段（读取路径必须保留，不做破坏性覆盖）：

- 宿主 `WindowConfig.extensionID` / `extensionStateReference` / `fileList` / 书签 / `mediaPlaybackMode`
- `FileListCueInfo.containerTrackID`（扩展队列 ID；不是 `FileListItem.id`）
- `ExtensionStateStore` 信封：`extensionID`、`schemaVersion`、`payload`（`ContentSession` JSON）
- `ContentSession.stateReference`：仍是存储键，不是私有恢复 blob

### 12.2 版本组合与退出条件

没有已发布二进制。兼容轴是协议世代，不是营销版本号。

| 世代 | 含义 |
| --- | --- |
| ABI v1 | `create_session` / `perform_command` / `release_bytes` / `destroy`；`perform_application_command` 为追加字段 |
| 会话 P0 | 旧 `hifi.*` 命令，无 `session.lifecycle` / `media.transport` / `ui.navigator-actions` |
| 会话 P1 | 上述三能力 v1 激活；本批当前开发树 |
| 设备 D0 | 现有 `AudioDeviceServiceRequest` JSON，宿主仍按 Hi-Fi 扩展 ID 查找 |
| 设备 D1 | 阶段 5 的能力发现入口，尚未定义 |

实际要支持：

| 组合 | 预期 | 退出前必须保留 |
| --- | --- | --- |
| P0 宿主 + P1 hifi | 新 hifi 继续接受 `hifi.*` | Runtime 旧命令入口 |
| P1 宿主 + P0 hifi | 缺能力则进 `HiFiLegacyAdapter`，不试发新消息 | 宿主兼容层 |
| P1 宿主 + P1 hifi | 通用协议，不经旧命令映射 | 无 |
| P1 宿主 + 无 hifi | 普通 PCM 与其他内置内容 | 无 |
| P1 宿主 + D0 | 现有应用级设备 JSON | 阶段 5 完成前 |

能力协商：无声明、未激活或版本不支持 → 隔离适配，禁止用发消息探测。新协议失败后不得自动改发旧命令。未知字段可忽略，未知枚举/操作必须拒绝。

`HiFiLegacyAdapter` 退出条件（阶段 6 删除前全部满足）：

1. 支持集不再包含 P0 宿主，或新 hifi 已明确放弃旧命令入口。
2. 支持集不再包含 P0 扩展；新宿主不再需要把通用动作编码为 `hifi.*`。
3. P0 `ContentSession` 快照可通过 `session.lifecycle` 或只读迁移恢复；不允许静默丢弃用户历史。
4. 设备 `hifi.device.*` 与固定扩展 ID 查找已由 D1 替换，且第 12.4 节硬件回归通过。
5. SACD 探测已在 hifi，宿主只调用通用探测入口。
6. 删除前需明确确认支持窗口已关闭。未满足前不得删除兼容层。

### 12.3 Fixture

共享、可分发，位于 `extension-kit/Sources/FoofoilExtensionKit/Fixtures/`。目录说明：`extension-kit/docs/phase0-baseline-fixtures.zh-CN.md`。

| 文件 | 用途 |
| --- | --- |
| `SessionLifecycleRequests.json` | 已有；关闭/恢复 |
| `MediaNavigationRequests.json` | 已有；供 smoke 执行的媒体/导航 |
| `AudioDeviceServiceMessages.json` | 本批；D0 请求、快照、未知字段、非法命令 |
| `LegacySessionCommands.json` | 本批；P0 `hifi.*` 命令 |
| `HistoryAndQueueSnapshots.json` | 本批；恢复请求、通用/容器队列、宿主 `WindowConfig` 子集、未进 smoke 的 play/selectDevice |

合成路径与 `test-dac-uid` / `track:stereo:01` 等不透明 ID；不含商业 ISO/DSF 或机器 DAC UID。

### 12.4 硬件已验证与未验证

已验证（交接文档第 4、6 节，SMSL USB AUDIO，不在本批重复）：立体声 DSD64 DSF/DFF；DSD128；DSD256；未压缩立体声 SACD ISO 列表/Seek/出声/两曲续播；DAC 释放屏障与切歌播放意图；拔出、占用/hog、睡眠恢复。5.0 DFF 在该 DAC 上为立体声折混。

本批未验证，不得标完成：play / `selectDevice` / `prepareExclusivePCM` 实机；同 DAC PCM/DSD 交接回归；无缝连播听感；系统默认输出与独占仲裁交互。

明确不在本轮范围：DST；SACD 多声道；环绕 DoP DAC 上的 5.0/5.1/7.1；Registry 安装；DSD→PCM 回退。

无硬件时：单元测试与 ABI smoke 不能替代听音结论。当前机器连有 SMSL，但本批未做听音。

### 12.5 验证

可重复命令：

```sh
# extension-kit
swift test

# hifi
swift test
swift run hifi-runtime-smoke --self-test \
  ../extension-kit/Sources/FoofoilExtensionKit/Fixtures/SessionLifecycleRequests.json \
  ../extension-kit/Sources/FoofoilExtensionKit/Fixtures/MediaNavigationRequests.json

# foofoil
xcodebuild test -project foofoil.xcodeproj -scheme foofoil -destination 'platform=macOS' -only-testing:foofoilTests
```

本批结果：

- extension-kit `swift test`：22 项通过（含新 baseline fixture 测试）。
- hifi `swift test`：40 项通过（含设备服务 fixture 键与 Runtime 命令表对照）。
- hifi smoke：生命周期、媒体/导航 ABI，以及 `perform_application_command` 的 `snapshot`；不播放合成 DSF，不 prepareExclusivePCM。
- 宿主单元测试：208 项通过、1 项硬件测试跳过、0 项失败；展开参数化测试后 223 次通过。跳过仍为 `CueSheetTests/exclusivePlaybackSurvivesTrackChangesAndPause()`。新增历史 fixture 解码：宿主 `FileListItem.id` 与 `containerTrackID` 分离。
- 三仓库 `git diff --check` 通过。文档与测试变更未执行 `./run`。
- 无新增源码编译警告。基线已有的 Selector/未使用变量/AppIntents 提示仍在。

### 12.6 剩余事项

阶段 0 验收已满足。阶段 1 见第 13 节。阶段 2 见第 14 节。

阶段 3 见第 15 节。阶段 4 见第 16 节。阶段 5 见第 17 节。阶段 6：见第 4 节未勾选项。硬件回归未通过前，阶段 5 不得标完成。

阻塞：无。阶段 6 删除旧适配前需按 12.2 确认支持窗口。

## 13. 实施记录：2026-09-10，阶段 1 从通用层移出 Hi-Fi 判断

本批基于 foofoil `0dd13c7`。只改宿主；复用第 8–11 节的兼容层与公共契约，不改 ABI、JSON、历史格式或 hifi 引擎。

### 已实现

新增宿主内部入口 `ExtensionPlaybackSupport`。通用 AppState / 导航 / 音频视图不再调用 `HiFiLegacyAdapter` 或解析 `hifi.*` / `file:`。兼容层仍掌握旧 provider、队列 ID 和命令映射，并标注阶段 3–5 替代路径：

- 阶段 4：呈现改为内容家族与已协商媒体能力，不再认 `audio.hifi`。
- 阶段 3：容器探测、私有曲目 ID 与可衔接格式由扩展解释。
- 阶段 5：独占交接按已协商设备服务决定，不把所有 `media.transport` 纳入抢占。

通用层改为：

- `ExtensionPresentationView` / `ExtensionAudioModeView` / `AppState+MediaType` 走 `usesHostAudioChrome` 与 `presentationURL`。
- `NavigatorPanelView` 走 `showsPlaybackIndicator`。
- 列表展开、无缝序列、容器安装、独占交接和旧菜单命令走 `containerPlaybackQueue` / `acceptsGaplessCollection` / `requiresExclusiveHandoff` / `legacyMediaAction`。
- `holdExtensionAudioFileAccess` 不再在 AppState 里解析 `file:` 前缀。
- 兼容队列方法改名为宿主语义（`contiguousExtensionAudioURLs`、`sessionByApplyingHostPlaybackSequence` 等）；实现仍只对旧 Hi-Fi 生效。
- 进程内 Provider 的 SACD 魔数 sniff 仅绑到 `audio.hifi`，其他 in-process 扩展不再共用该探测。

行为保持：通用测试 Provider 即使带 `mediaPlayback` 和队列，也不会进入宿主音频 chrome、容器展开或独占交接。

### 验证

- `xcodebuild test ... -only-testing:foofoilTests`：211 项通过、1 项硬件测试跳过、0 失败；展开参数化测试后 226 次通过。跳过仍为 `CueSheetTests/exclusivePlaybackSurvivesTrackChangesAndPause()`。
- 新增 `ExtensionPlaybackSupportTests`：通用 Provider 不接管呈现/队列/交接；Hi-Fi 仍走旧 chrome 与 `file:` 资源定位；通用队列不会被安装成宿主容器。
- `./run` 构建、注入并签名 Hi-Fi 开发插件后启动应用。未做真实 DAC 听音或设备切换。
- `git diff --check` 通过；无新增源码编译警告。未改 extension-kit 或 hifi，未重复跑两者测试。

### 剩余事项

阶段 1 验收已满足。适配层仍有专用知识，这是本阶段允许的。

阶段 3 起：将 SACD 探测迁入 hifi、解释私有 ID、按内容家族呈现、完成设备独占交接。设备服务已能按能力发现，无声明时仍回退 Hi-Fi 扩展 ID。

## 14. 实施记录：2026-09-10，阶段 2 最小通用契约

本批修改 extension-kit 与 foofoil；hifi 引擎与 ABI 未改。复用已有 `media.transport`、`session.lifecycle`、`ui.navigator-actions` 和 `AudioDeviceServiceRequest`。

### 已实现

- `MediaPlaybackSnapshot.availableActions`：显式禁用列表；缺省由状态、`isSeekable` 和队列长度推导。显式列表外的动作在进扩展前返回 `actionUnavailable`。通用呈现控件与扩展播放控制器接入该禁用状态。
- 列表所有权写入契约：宿主拥有外部文件顺序；扩展拥有容器曲目；项目 ID 不透明。导航动作使用会话贡献 ID，不再写死 `hifi.playback-queue`。`file:` 前缀只留在兼容层。单资源且队列 ≥2 视为容器投影，通用 Provider 也可展开。
- `stateReference` 继续只作 `ExtensionStateStore` 键。不透明状态即已持久化的 `ContentSession` payload；恢复请求仍只传曲目 ID 与位置，不新增 blob。
- 新增 `content.probe` v1（application）。请求走 `perform_application_command` 的 `commandID`，与设备服务的 `command` 字段并存。I/O 预算默认 2 MiB。本批未把 SACD 嗅探迁出宿主兼容层。
- 设备服务按 Manifest 协商 `audio.device-selection`：audio 域偏好优先，否则唯一候选，否则不用并保留系统输出。未声明能力的旧 Hi-Fi 仍按扩展 ID 回退。

最小非 Hi-Fi Provider `test.generic-audio` 用 `item-a` / `item-b` 完成播放、导航、恢复、幂等关闭，不含 `hifi.*`。

### 验证

- extension-kit `swift test`：26 项通过。
- hifi `swift test`：40 项通过（未改 Runtime）。
- 宿主：214 项通过、1 项硬件跳过、0 失败；展开 229 次。跳过仍为 `CueSheetTests/exclusivePlaybackSurvivesTrackChangesAndPause()`。
- `./run` 构建、注入并签名 Hi-Fi 开发插件后启动。未做 DAC 听音。
- 两仓库 `git diff --check` 通过。

### 剩余事项

阶段 2 验收已满足。阶段 3 见第 15 节。阶段 4：按内容家族呈现。阶段 5：独占交接与去掉 Hi-Fi ID 回退。硬件回归未通过前阶段 5 不得标完成。

## 15. 实施记录：2026-09-10，阶段 3 格式、导航与恢复语义下沉

本批修改 hifi 与 foofoil；extension-kit 契约未改，复用阶段 2 的 `content.probe` v1。不改 PCM 引擎、窗口或历史库。

### 已实现

- hifi 声明并实现 `content.probe`：只在 I/O 预算内读 Scarlet Book 主 TOC 魔数，不建会话、不碰设备。普通 ISO、DSF 和过小预算返回 `unmatched`；命中返回 `matched` / `reason: sacd-master-toc`。
- 宿主 `InProcessContentProvider` 在已声明该能力时调用探测；未声明的旧 Hi-Fi 仍走 `HiFiLegacyAdapter.sniffSACDISOMagic`。
- 宿主不再解析 `file:` 前缀或曲目序号。队列对应改为：`containerTrackID`、列表上的不透明 `extensionItemID` 盖章，以及资源与队列 1:1 配对。
- 连续可衔接文件按同一非内置音频 Provider 收集，嗅探命中的容器单独打开，不再写死 `dsf`/`dff`。
- 历史恢复时资源缺失或嗅探不再命中，降级为 `unavailable` 呈现；新会话 UUID 不复用已关闭会话。

探测 v1 不含曲目列表，追加 ISO 展开仍开临时会话读取 `playbackQueue`。呈现 chrome 与独占交接仍 Hi-Fi 门控（阶段 4–5）。

### 验证

- hifi `swift test`：43 项通过（含 Runtime `content.probe` ABI 与契约 fixture 键）。
- hifi smoke `--self-test`：生命周期、媒体/导航，以及 DSF / 普通 ISO / 魔数 ISO / 过小预算探测。不播放合成 DSF，不 prepareExclusivePCM。
- 宿主：219 项通过、1 项硬件跳过、0 失败；展开 235 次。跳过仍为 `CueSheetTests/exclusivePlaybackSurvivesTrackChangesAndPause()`。
- `./run` 构建、注入并签名 Hi-Fi 开发插件后启动。未做 DAC 听音。
- 两仓库 `git diff --check` 通过。无新增源码编译警告。未改 extension-kit，未重复跑其测试。

### 剩余事项

阶段 3 验收已满足。阶段 4 见第 16 节。阶段 5：独占交接与去掉 Hi-Fi ID 回退。硬件回归未通过前阶段 5 不得标完成。

## 16. 实施记录：2026-09-10，阶段 4 通用会话与呈现

本批只改宿主；不改 ABI、JSON、历史格式或 hifi 引擎。独占交接与设备服务仍走兼容层（阶段 5）。

### 已实现

- `usesHostAudioChrome` 按内容家族与已协商 `media.transport` 决定，不再认 `audio.hifi`。有播放快照的通用音频 Provider 复用 `ExtensionAudioModeView`；无快照的增强器仍走通用文本呈现。
- 无缝序列 `acceptsGaplessCollection` 跟随音频 chrome，不再写死 Hi-Fi。
- 正在播放指示使用会话播放贡献 ID，不再认 `hifi.playback-queue`。宿主文件列表的音视频指示保持原路径。
- `requiresExclusiveHandoff` 与旧命令映射仍留在兼容层，阶段 5 再按设备服务解耦。
- 过期媒体结果不得覆盖新会话：会话 UUID 与 `exclusivePlaybackGeneration` 防护已有测试覆盖。

### 验证

- 宿主：221 项通过、1 项硬件跳过、0 失败；展开 237 次。跳过仍为 `CueSheetTests/exclusivePlaybackSurvivesTrackChangesAndPause()`。
- `GenericAudioContractTests`：通用 Provider 走音频 chrome、贡献 ID 指示、导航/恢复/关闭；过期 play 不覆盖新会话。无 `media.transport` 的会话不进入音频 UI。Hi-Fi 仍独占交接。
- `./run` 构建、注入并签名 Hi-Fi 开发插件后启动。未做 DAC 听音。
- `git diff --check` 通过。无新增源码编译警告。未改 extension-kit 或 hifi。

### 剩余事项

阶段 4 验收已满足。阶段 5 见第 17 节。阶段 6：目录整理与旧适配删除。

## 17. 实施记录：2026-09-10，阶段 5 设备服务解耦（代码完成，听音未完成）

本批只改宿主。不改 ABI、JSON、历史格式或 hifi 引擎。不把所有 `media.transport` 纳入独占。

### 已实现

- `ExtensionHost` 只按 Manifest `audio.device-selection` 与 audio 域偏好选择设备服务；无唯一候选则不用，保留系统 PCM。去掉按 Hi-Fi 扩展 ID 回退。
- `requiresExclusiveHandoff` 跟随已协商设备服务或会话设备快照，不再认 `audio.hifi`。
- 扩展音频 chrome 仅在使用设备服务时监听系统设备，用于刷新菜单；DSD 拔出/hog 仍由扩展 `DeviceLifecycleWatch` 负责。PCM 独占路径的宿主监听保留。
- 跨窗口交接仍走 `ExclusivePlaybackCoordinator`：先暂停并释放旧持有者，再启动新持有者；系统默认输出不登记。

### 验证

- 宿主：222 项通过、1 项硬件跳过、0 失败；展开 238 次。无 `FOOFOIL_TEST_DAC_UID` 时跳过仍为 `CueSheetTests/exclusivePlaybackSurvivesTrackChangesAndPause()`。
- 传入 `TEST_RUNNER_FOOFOIL_TEST_DAC_UID=AppleUSBAudioEngine:SMSL:SMSL USB AUDIO:141200:1` 后该用例在 xcodebuild 测试进程中失败：测试宿主未注入 Hi-Fi 插件，`isAudioDeviceServiceAvailable` 为 false。不以该失败当作设备路径回归。
- `./run` 构建、注入并签名 Hi-Fi 开发插件后启动。未做 DSD 听音，未做同 DAC PCM/DSD 交接听音。
- `git diff --check` 通过。无新增源码编译警告。未改 extension-kit 或 hifi。

### 剩余事项 / 阻塞

实施当时阶段 5 验收未满足：同 DAC PCM/DSD 交接、`selectDevice` / `prepareExclusivePCM` 实机听音尚未验证。测试宿主无开发插件的问题见上文，后续以 `./run` 的实际应用手动验证补齐。

### 2026-09-10 用户实机补验

用户在本任务中确认“以上手动测试已通过”，覆盖此前提供的清单：同一 SMSL DAC 的 PCM 独占 → DSD、DSD → PCM、快速交替 10 次、交接中关闭新窗口、设备拔出重接、退出后其他应用使用 DAC，以及系统默认 PCM 输出回归。选择 DAC 和 PCM 独占播放覆盖 `selectDevice` / `prepareExclusivePCM` 实际路径。

结果来源是用户操作与听音反馈，非 agent 现场观测；未提供逐项日志、具体媒体文件/采样率和独立版本号，不补造这些数据。自动测试负责释放/获取顺序的代码证据，手动回归负责真实设备出声与恢复行为。不将本次结果扩大到所有 DSD 采样率、多声道或无缝连播听感。

阶段 5 验收满足，解除进入阶段 6 的阻塞。此前各节“未做听音”保留为当批历史记录，以本补验更新当前状态。


## 18. 实施记录：2026-09-10，阶段 6 结构与兼容范围收尾

基线：foofoil `12ab025`（已有阶段 5 未提交修改，本批保留）、extension-kit `6a617c2`、hifi `334d71d`。本批仅修改宿主源码/测试与文档，不改 ABI、JSON、播放算法或硬件策略。

### 已实现

- 原 `foofoil/ExtensionKit/` 已移入 `foofoil/ExtensionSupport/`，按 Runtime、Management、Presentation、Compatibility 归类。独立 extension-kit 与宿主 `foofoil/Extensions/` 不变。
- 将 `ExtensionAudioPlaybackController` 从音频视图文件拆出；UI 和播放控制适配器继续留在宿主。
- 已通用化的 `AppState+HiFiLegacyQueue.swift` 改为 Presentation 下的 `AppState+ExtensionQueue.swift`，更新职责注释。
- 设备 ABI 包装改为 Runtime 下的 `InProcessAudioDeviceService`，删除未使用的固定 Hi-Fi ID 查找入口与常量；原请求传递、线程和错误传播测试继续覆盖该包装。
- Provider 的旧版内容识别判断也收进 Compatibility。生产 Swift 源码中的 `audio.hifi`、`hifi.*` 与 `SACDMTOC` 字面量仅位于该目录；通用层保留明确的兼容入口调用，不解析私有 ID。
- 保留 P0 兼容范围：旧媒体/菜单设备选择、导航、关闭、恢复及缺少新探测能力时的 SACD 探测。P0 支持窗口尚未关闭，不删除仍需支持的适配；退出条件继续遵循 §12.2。应用级固定 ID 设备服务回退已删除。阶段 6 按“仍需支持旧版则明确保留范围与删除条件”完成该项。
- 更新中英文 README、AGENTS，新增 `docs/extension-support.zh-CN.md`。Xcode 使用文件系统同步源码组，检查确认无旧目录显式引用，无需修改 pbxproj；后续构建验证新路径被正确编译。历史实施记录中的旧路径保留为基线说明。

### 源码与职责复核

统计 `.swift`，包含注释/空行，不含测试：

| 部分 | 阶段 0 基线 | 当前 |
| --- | ---: | ---: |
| foofoil/foofoil | 25,452 | 25,981 |
| 其中 AppState 目录 | 5,610 | 5,440 |
| 宿主扩展支持目录（原 ExtensionKit） | 3,783 | 4,477 |
| extension-kit/Sources | 1,453 | 1,764 |
| hifi/Sources | 5,534 | 6,006 |

ExtensionSupport 当前：Runtime 1,599 行、Management 1,561 行、Presentation 1,092 行、Compatibility 225 行。AppState 目录数字不包含现位于 Presentation 的队列桥接，不能将移动的行数认作逻辑删除。

总体源码没有减少；收益是通用路径按契约工作、设备/格式实现归属明确，以及旧版特例限制在可退出的兼容范围。新增契约与兼容支持有实际维护成本，不声称目录移动带来体积或性能收益。

### 验证

- 宿主 `xcodebuild test ... -only-testing:foofoilTests`：222 项通过，展开参数化后 237 次通过，1 项 DAC 自动测试跳过，0 失败。包括旧历史/协议、通用 Provider、设备服务请求/线程/错误传播及队列回归。
- 跳过仍为 `CueSheetTests/exclusivePlaybackSurvivesTrackChangesAndPause()`；真实设备结论由 §17 用户补验提供，不伪装成自动测试通过。
- 拆分文件时发现缺失 Combine 导入，已修复后重跑通过；未新增源码编译警告，既有测试 Selector/未使用变量与 AppIntents 提示仍在。
- extension-kit、hifi 源码未修改，不重复其单元测试；开发插件联调由 `./run` 验证。
- `./run` 成功完成宿主构建、开发版 hifi 插件构建/注入/签名与应用启动。
- `git diff --check` 通过；阶段 6 验收满足。后续删除旧适配须单独关闭支持窗口，本批未作此决定。

## 19. 后续回归：2026-09-10，PCM 连播与 CUE 首次播放

用户报告：独立 PCM 文件在同采样率自动切曲时停顿，独占和系统默认输出均发生；CUE 播放出现崩溃。DSD 未报告此问题。此反馈补充阶段验收范围，不将之前的设备交接通过结论等同于 PCM 无缝播放已验证。

定位证据：11:01–11:03 的应用日志在崩溃前记录 `player started when in a disconnected state`，调用来自 `AudioPlaybackController.schedule` → `AVAudioPlayerNode.play`。首次惰性创建引擎只 attach 节点，没有连接 mixer；原连播测试先选择系统默认输出，重建路由时建立连接，掩盖了首次播放路径。另一个问题是用默认的 data-consumed 回调推进列表：SDK 明确允许它在开始渲染前或实际播放结束前触发，原 0.4 秒测试也在数十毫秒内报告完成，未验证真实边界。两处实现均已存在于 `9c583f4`，早于阶段 6 目录整理；不据此断言所有用户听到的停顿都只有这两个原因。

修复：首次创建引擎即按文件格式连接 player → mixer；段完成通知改为 `dataPlayedBack`，同格式下一曲继续预排在同一节点；为预排文件持有安全范围访问直至替换/取消/销毁。未改 hifi、HAL/DoP 或跨窗口独占交接策略。

回归测试改为三首实际播放，覆盖独立 WAV 与同文件 CUE 范围，直接首次 play，不预先重建系统路由；模拟列表推进后的 load，检查中间两次保持播放、完成时间符合各段实际时长、最后一段完整结束。针对性 CueSheetTests 已通过，真实音乐/DAC 听感仍需用户复验。

最终验证：宿主单元测试 222 项通过，展开参数化后 239 次通过，1 项 DAC 自动测试跳过，0 失败；`./run` 构建、开发插件注入/签名及启动成功。`git diff --check` 通过，无新增源码编译警告。尚未由用户确认修复后的真实音乐听感与 CUE 操作结果。
