# 媒体控制与导航动作 v1

两种消息均复用 Extension API v1 的 `perform_command`。成功返回更新的 `ContentSession`；没有新增 C ABI 字段。宿主必须按新会话中激活的能力选择协议，不以试发消息来探测支持情况。

## 媒体控制

能力为 `media.transport`，版本 1，scope 为 `session`。消息类型为 `MediaPlaybackRequest`：

```json
{
  "commandID": "media.transport",
  "contractVersion": 1,
  "action": { "kind": "seek", "position": 42 },
  "session": {}
}
```

示例中的 `session` 必须替换为当前有效会话。`action` 是 `MediaPlaybackAction`：

| kind | 参数 | 语义 |
| --- | --- | --- |
| play | 无 | 请求播放，结果可能是 playing 或带失败原因的快照 |
| pause | 无 | 请求暂停，释放要求由扩展对应输出能力决定 |
| refresh | 无 | 获取最新状态，不能视为用户主动起播 |
| previous / next | 无 | 切到扩展队列相邻项；边界行为由扩展报告，宿主文件列表仍由宿主控制 |
| seek | position | 有限且非负的秒数；要求快照可定位，由扩展按真实时长和格式粒度限制 |
| selectDevice | deviceID | 非空稳定设备 ID；扩展按实际设备状态验证，不信任陈旧菜单快照 |
| selectSystemDefault | 无 | 扩展管理持续跟随系统默认输出；仅在 availableActions 显式声明时显示跟随能力 |

`MediaPlaybackSnapshot.availableActions` 为可选显式可用动作列表。缺省时宿主按状态、`isSeekable` 和队列长度推导禁用：非 playing/loading 可 play，playing 可 pause，可定位才 seek，队列多于一项才 previous/next，refresh 与 selectDevice 默认可用。显式列表存在时，列表外的动作在进扩展前拒绝（`actionUnavailable`）。未知动作枚举必须拒绝。

非法参数在产生播放或设备副作用前拒绝。宿主仍负责跨窗口的播放意图和现有独占交接；本能力本身不表示所有 Provider 都使用独占输出。

## 列表所有权

宿主 `FileListState` 拥有外部文件的顺序、当前项和循环/随机意图。扩展 `playbackQueue` / `ui.navigator` 贡献拥有容器内部曲目。项目 ID 对宿主不透明；宿主不得合成 `file:` 一类私有前缀，也不得写死 `hifi.playback-queue`。导航动作使用会话里实际贡献 ID。容器投影把扩展 ID 存在 `FileListCueInfo.containerTrackID`，宿主列表项 ID 仍由宿主分配。

## 导航动作

能力为 `ui.navigator-actions`，版本 1，scope 为 `presentation`。已有 `ui.navigator` 只表示导航贡献，不保证理解新的动作消息，不能替代此能力检查。

消息类型为 `NavigatorActionRequest`，`commandID` 为 `ui.navigator.action`，`contractVersion` 为 1，包含当前 `session` 和原有 `NavigatorAction`：

```json
{
  "contributionID": "provider-owned-queue",
  "kind": "move",
  "itemIDs": ["opaque-item-id"],
  "destinationItemID": "another-item-id",
  "movePosition": "before"
}
```

`contributionID` 和 `itemIDs` 对宿主不透明。操作遵守贡献的 `allowedActions`：activate 只能有一个项目；move 需要 before/after/end；before/after 的目标不能是被移动项目；end 不携带目标。多项目移动保持项目在原列表中的相对顺序，不按请求数组重新排序。remove 只有贡献允许时可执行。

宿主发送前验证贡献与动作。扩展还必须以自己的实时列表再次验证，不能仅凭客户端快照的 allowedActions 或伪造项目执行。Hi-Fi 目前仅支持 activate 和普通文件队列的 move；SACD 容器不允许 move，所有 Hi-Fi 队列均不允许 remove。

## 兼容与错误

缺少能力、能力未激活、版本不支持时，新宿主对旧 Hi-Fi 使用兼容适配。原来的 hifi.* 命令仍保留，新插件继续兼容旧宿主。新协议调用失败后不能自动改发旧命令重试，避免重复副作用。

本版未删除旧命令贡献，也未改变导航贡献的 ID。Hi-Fi 菜单中的旧命令在宿主的兼容入口翻译为媒体动作，后续实际调用可按能力使用新协议。其余插件的自定义命令保持原通道。

未知操作或协议版本必须拒绝；未知附加字段可忽略。Hi-Fi 沿用 ABI 返回码：消息格式错误为 1，执行或实时语义验证失败为 3；播放硬件失败也可能沿用既有 failed 快照报告，不保证所有硬件失败都通过 ABI 非零返回。

## 验证

共享 fixture 为 `Sources/FoofoilExtensionKit/Fixtures/MediaNavigationRequests.json`。契约测试验证编码与解码，hifi smoke 测试使用同一文件经真实 C ABI 执行：

```sh
# extension-kit 仓库
swift test

# hifi 仓库
swift test
swift run hifi-runtime-smoke --self-test ../extension-kit/Sources/FoofoilExtensionKit/Fixtures/SessionLifecycleRequests.json ../extension-kit/Sources/FoofoilExtensionKit/Fixtures/MediaNavigationRequests.json
```

smoke 覆盖暂停、定位、刷新、前后切曲、激活、排序、非法参数和导航动作拒绝，并保留关闭/恢复的兼容回归。合成 DSF 不用于起播或真实设备切换；play 和 selectDevice 的硬件行为仍需真实 DAC 回归。

系统默认路由的 `audioDeviceSelection.followsSystemDefault` 是可选布尔值；缺省不推断为跟随。`selectedDeviceID` 仍报告实际设备 UID，供音量和状态显示使用。宿主发送一次 `selectSystemDefault` 后，由扩展处理默认设备变化，不能在快照刷新时再发送 `selectDevice`。
