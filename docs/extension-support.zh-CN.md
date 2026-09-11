# 宿主扩展开发说明

`foofoil/ExtensionSupport/` 是宿主实现；兄弟仓库 `extension-kit` 是公共契约，两者不是重复的插件 SDK。

| 目录 | 职责 |
| --- | --- |
| Runtime | Provider、加载与进程连接、能力解析、会话存储/生命周期、应用级设备服务 |
| Management | 安装/归档、Manifest 兼容性协商、Manager、Registry |
| Presentation | 宿主视图、独立的播放控制适配器、媒体动作和宿主文件列表/扩展队列桥接 |

`ExtensionAudioModeView.swift` 只负责呈现；`ExtensionAudioPlaybackController.swift` 将快照和通用动作接入宿主媒体控件。窗口、快捷键、封面、权限和历史仍归宿主。DSF/DFF/SACD 解析、HAL/DoP、设备租约与格式恢复归 hifi。公共 JSON/ABI/Manifest 契约归 extension-kit。

`foofoil/Extensions/` 保留 Swift 和系统类型扩展。Xcode 的 `PBXFileSystemSynchronizedRootGroup` 自动发现源码树中的文件，目录移动无需手工增加 Sources 条目。不要把本地包产品 `FoofoilExtensionKit` 重命名为宿主目录名。

## 兼容支持

P0 支持窗口已关闭，`ExtensionSupport/Compatibility/` 与 `HiFiLegacyAdapter` 已删除。

- 宿主只消费当前公共契约：`session.lifecycle`、`media.transport`、`ui.navigator-actions`、`content.probe`、`audio.device-selection`。缺失能力时明确不支持，不回退旧 `hifi.*` 命令。
- 标准播放/暂停/定位/切曲/设备操作由宿主媒体 UI 与公共能力承接；hifi 不再贡献对应 `hifi.*` 菜单命令。
- 媒体动作可用性统一来自公共 `availableActions` 与设备连接快照，不读旧 command 的 `isEnabled`。
- 不保留仅服务未发布 P0 的 fixture 与测试；C ABI v1 函数表、当前版本重启/恢复与资源生命周期保障仍然保留。
- 历史数据继续按既有方式读取，不批量改写或丢弃旧记录。

## 验证

在宿主仓库执行：

```sh
xcodebuild test -project foofoil.xcodeproj -scheme foofoil -destination 'platform=macOS' -only-testing:foofoilTests
./run
```

`./run` 会构建、注入并签名开发版 hifi 插件，然后启动应用。普通 xcodebuild 测试宿主不自动注入该插件；缺插件时 DAC 测试的失败/跳过不能当作真实设备验证。

契约或 Runtime 改动另外运行对应仓库 `swift test` 和 ABI smoke。真实 DAC 回归以用户的实机记录为准；目录整理不增加新的硬件覆盖结论。
