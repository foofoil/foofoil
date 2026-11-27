# 内容探测 v1

可选 application-scope 能力 `content.probe`，`contractVersion: 1`。用于会话建立前识别资源，不创建播放会话、不获取输出设备。走 ABI v1 `perform_application_command`；请求带 `commandID: "content.probe"`，以便与现有设备服务 JSON（以 `command` 区分 snapshot/prepareExclusivePCM 等）共存。

缺少能力、版本不支持或 scope 不是 application 时，宿主不得试发探测消息，可回退到本地后缀匹配或兼容层嗅探。

## 请求

| 字段 | 要求 |
| --- | --- |
| `commandID` | 固定 `content.probe` |
| `contractVersion` | `1` |
| `resource` | 已授权的 `ExtensionResource` |
| `maxReadBytes` | 正整数；默认 2,097,152。扩展不得超出预算读文件 |

未知附加字段可忽略。未知 `commandID` 或版本必须拒绝。

## 结果

| 字段 | 要求 |
| --- | --- |
| `disposition` | `matched` 或 `unmatched` |
| `reason` | 可选说明，不作为协议枚举 |
| `itemCount` / `title` | 可选；容器匹配时可提供曲目数与标题 |

普通 ISO 必须 `unmatched`。匹配不等于已经建好播放会话。

共享 fixture：`Sources/FoofoilExtensionKit/Fixtures/ContentProbeRequests.json`。
