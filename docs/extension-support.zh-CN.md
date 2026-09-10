# 宿主扩展开发说明

`foofoil/ExtensionSupport/` 是宿主实现；兄弟仓库 `extension-kit` 是公共契约，两者不是重复的插件 SDK。

| 目录 | 职责 |
| --- | --- |
| Runtime | Provider、加载与进程连接、能力解析、会话存储/生命周期、应用级设备服务 |
| Management | 安装/归档、Manifest 兼容性协商、Manager、Registry |
| Presentation | 宿主视图、独立的播放控制适配器、媒体动作和宿主文件列表/扩展队列桥接 |
| Compatibility | 仍支持的旧 Hi-Fi 会话、命令、导航、恢复和内容探测 |

`ExtensionAudioModeView.swift` 只负责呈现；`ExtensionAudioPlaybackController.swift` 将快照和通用动作接入宿主媒体控件。窗口、快捷键、封面、权限和历史仍归宿主。DSF/DFF/SACD 解析、HAL/DoP、设备租约与格式恢复归 hifi。公共 JSON/ABI/Manifest 契约归 extension-kit。

`foofoil/Extensions/` 保留 Swift 和系统类型扩展。Xcode 的 `PBXFileSystemSynchronizedRootGroup` 自动发现源码树中的文件，目录移动无需手工增加 Sources 条目。不要把本地包产品 `FoofoilExtensionKit` 重命名为宿主目录名。

## 兼容支持

P0 旧宿主/旧扩展支持窗口仍开放，见[计划 §12.2](extension-boundary-refactor-plan.zh-CN.md#122-版本组合与退出条件)。本轮没有撤销旧版支持。

- 保留 `HiFiLegacyAdapter` 的旧媒体/设备选择命令、导航、关闭、恢复与未声明 `content.probe` 时的 SACD 探测。仅在能力缺失的显式兼容入口使用；新协议执行失败不得重试旧协议。
- 历史数据继续按既有方式读取，不批量改写或丢弃旧记录。
- 应用级设备服务只按 `audio.device-selection` 能力协商。`InProcessAudioDeviceService` 是通用 ABI 包装；无能力时保留普通 PCM 系统输出，不按固定 Hi-Fi ID 回退。
- 已通用化的队列桥接位于 Presentation，不属于旧版兼容层。

删除剩余适配前，必须满足计划 §12.2 全部条件：关闭 P0 宿主与扩展支持范围，验证历史可恢复，确认设备与探测迁移完成，并明确记录支持窗口关闭。阶段 6 采用计划允许的“保留有限兼容范围”方案，不以目录整理作为废弃协议的理由。

## 验证

在宿主仓库执行：

```sh
xcodebuild test -project foofoil.xcodeproj -scheme foofoil -destination 'platform=macOS' -only-testing:foofoilTests
./run
```

`./run` 会构建、注入并签名开发版 hifi 插件，然后启动应用。普通 xcodebuild 测试宿主不自动注入该插件；缺插件时 DAC 测试的失败/跳过不能当作真实设备验证。

契约或 Runtime 改动另外运行对应仓库 `swift test` 和 ABI smoke。真实 DAC 回归以计划 §17 的用户实机记录为准；本轮目录整理不增加新的硬件覆盖结论。
