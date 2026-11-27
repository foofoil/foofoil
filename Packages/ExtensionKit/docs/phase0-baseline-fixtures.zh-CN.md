# 阶段 0 基线 fixture

这些 JSON 描述当前跨仓库消息和持久化形状，供契约测试、Runtime 解析和宿主历史解码共用。测试数据全部合成，不含商业 SACD/DSF 或真实 DAC UID。

| 文件 | 覆盖 |
| --- | --- |
| `Fixtures/SessionLifecycleRequests.json` | `session.lifecycle` v1 关闭/恢复 |
| `Fixtures/MediaNavigationRequests.json` | `media.transport` / `ui.navigator.action`；供 hifi smoke 执行 |
| `Fixtures/AudioDeviceServiceMessages.json` | 应用级设备服务请求与快照，走 `perform_application_command` |
| `Fixtures/HistoryAndQueueSnapshots.json` | 恢复请求、通用/容器队列、宿主 `WindowConfig` 子集、未进入 smoke 的 play/selectDevice |

## 设备服务

请求体是 `AudioDeviceServiceRequest`，不经过 `perform_command`，也没有 `commandID`。命令为 `snapshot`、`selectSystemDefault`、`prepareExclusivePCM`、`releasePCM`、`releaseAllPCM`。`clientID` 防止旧箔释放新箔的租约。

`prepareExclusivePCM` 在 Codable 层允许缺少设备字段；Runtime 在取得独占前拒绝不完整请求。未知附加字段可忽略，未知 `command` 不能解码。

smoke 只对 `snapshot` 走真实 ABI，不调用 `prepareExclusivePCM`，不替代 DAC 独占回归。

## 历史与队列

宿主持久化 `extensionID`、`extensionStateReference`、授权书签和 `FileListState`。扩展 payload 是 `ContentSession` JSON，由 `ExtensionStateStore` 按引用保存。`stateReference` 仍是该存储键，不是私有恢复 blob。

容器曲目 ID（如 `track:stereo:01`）只在扩展队列内有效。宿主 `FileListItem.id` 使用 `sacd:{section}:{index}:{trackID}`，并把扩展 ID 放在 `cue.containerTrackID`。容器贡献只允许 `activate`。

## 验证

```sh
# extension-kit
swift test

# hifi
swift test
swift run hifi-runtime-smoke --self-test \
  ../extension-kit/Sources/FoofoilExtensionKit/Fixtures/SessionLifecycleRequests.json \
  ../extension-kit/Sources/FoofoilExtensionKit/Fixtures/MediaNavigationRequests.json
```
