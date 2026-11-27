# 会话生命周期契约 v1

本契约定义关闭和媒体历史恢复，复用 Extension API v1 的 `perform_command` JSON 入口。C 函数表没有新增字段；UI、播放控制、设备服务和内容探测不属于本契约。

## 发现与兼容

扩展在 Manifest 声明 `session.lifecycle`，`contractVersion: 1`、`scope: session`，并在实际支持的会话能力中将其标为 `active`。宿主只有在会话声明该版本且已激活时才能发送本消息。没有能力声明、尚未激活或只有不支持的版本，均不能试发消息来探测支持情况。

已有字段与旧命令保留：旧宿主可继续使用扩展原有命令；新宿主遇到旧 Hi-Fi 时使用隔离的旧协议适配。新宿主收到新协议的错误后不自动重放旧协议，以免重复执行已有副作用。扩展收到未知操作或不支持的契约版本必须拒绝，不得当作状态查询成功返回。

## JSON 消息

`SessionLifecycleRequest` 的字段：

| 字段 | 要求 |
| --- | --- |
| `commandID` | 固定为 `session.lifecycle` |
| `contractVersion` | 必填整数 `1` |
| `operation` | `close` 或 `restore` |
| `session` | 当前运行时会话快照，包含当前有效的会话 UUID |
| `restoration` | 仅 `restore` 必填；`close` 不得携带非空值 |

`restoration` 是 `PlaybackRestorationState`：`currentItemID` 为可选非空字符串，ID 的含义由扩展解释；`position` 为可选、有限且非负的秒数。字段缺失表示不请求对应恢复操作。未知附加字段可忽略，未知操作值不可忽略。

完整实例在 `Sources/FoofoilExtensionKit/Fixtures/SessionLifecycleRequests.json`。该文件由契约测试编码/解码，同时传给 hifi 的 Runtime smoke 测试，经真实 C ABI 执行。

## close

成功响应仍为 `ContentSession`，播放状态为 `stopped`。成功必须发生在会话资源释放完成之后。重复关闭已移除的会话返回成功，不重建会话或重新获取设备。无效 UUID 不是有效关闭请求。

释放失败返回非零 ABI 状态，不能提前删除记录或假报成功。Runtime 错误如何展示、是否重试由宿主生命周期策略决定；本契约不改变现有宿主记录关闭错误的行为。

## restore

宿主先用原资源请求和授权创建新会话，再把旧历史中的曲目 ID、位置发送给该新会话。不重放旧 Session UUID、旧设备对象 ID 或旧的播放意图。不同 Provider 之间不传递恢复状态。

扩展负责解释曲目 ID、选择曲目、按新曲目实际时长限制位置，并在必要时按格式的定位粒度对齐。恢复不会启动播放或获取新的输出设备；成功的正常恢复保持暂停。对正在播放的会话发送恢复请求应拒绝，宿主应使用新建会话。

指定曲目已不存在时，返回当前会话而不把旧位置套到其他曲目。历史位置损坏时宿主可以省略位置并保留其他可恢复值；在线请求中的非法位置仍须拒绝。

v1 只覆盖现有媒体快照可表达的曲目与位置。`ContentSession.stateReference` 仍是宿主 `ExtensionStateStore` 的存储键，不是私有恢复 blob。不透明扩展状态由宿主持久化的 `ContentSession` payload 承载；恢复请求只把扩展必须解释的曲目 ID 与位置发给新会话。本轮不新增恢复 blob 字段，以免改变 `stateReference` 的既有含义。书签与历史数据库仍归宿主。

## 验证命令

```sh
# extension-kit 仓库
swift test

# hifi 仓库，要求兄弟 extension-kit 检出包含本契约
swift test
swift run hifi-runtime-smoke --self-test ../extension-kit/Sources/FoofoilExtensionKit/Fixtures/SessionLifecycleRequests.json
```

smoke 测试使用合成 DSF 元数据，检查旧命令兼容、新协议恢复、错误拒绝、关闭幂等与记录释放；不播放合成音频，不代替真实 DAC 回归。
