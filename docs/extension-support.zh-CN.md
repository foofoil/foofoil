# 宿主扩展开发说明

## 当前产品策略（2026-09-29）

扩展/插件仅用于开发阶段的模块拆分、联调与验证。最终产品不提供扩展概念：Hi-Fi、EPUB 等能力随浮箔统一交付，用户无需安装、启用或更新单独插件。独立仓库不等于独立产品，也不再以 Registry、扩展市场或 Extension Manager 为产品目标。

当前工程仍通过 C ABI、JSON、Manifest 与 `.foofoilextension` 包连接内部模块。这些名称及 Runtime / Management / Presentation 的分层可以继续用于描述源码；Management 中的安装、下载、更新、Registry 和“扩展”设置页实现均保留，由 `ExtensionProductPolicy.exposesUserManagement`（当前为 false）统一隐藏设置/菜单入口、停止启动更新检查并禁用安装提示。该开关不影响内置内容运行时；未来重新启用时可复用现有实现。

- `extension-kit`：工程必需的本地 Swift 包，维护内部共享契约与契约测试。
- `hifi` / `ebook`：分别维护音频与 EPUB 实现，保留清晰的解析、设备及资源生命周期边界。
- `./run`：构建并嵌入相邻 `hifi`、`ebook` 的 Debug 模块；缺少构建脚本时跳过对应能力。
- `./package-dmg`：构建 Release 并将两个模块嵌入 `foofoil.app`，统一签名/公证（选择签名模式时）及打包；完整分发需要全部兄弟仓库。
- Xcode ⌘R 和普通 `xcodebuild` 不执行上述模块嵌入步骤。联合编辑使用 `foofoil.xcworkspace`。

旧扩展系统方案、边界重构报告及 Phase 0 验证文档保留为技术与验收记录。其按需安装、独立发布、公开插件平台和 Registry 路线已被本策略取代；协议、职责边界和测试记录仍可参考。不要把过去的计划或验收结果当作当前发布承诺。

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

`./run` 会构建、嵌入并签名开发版 hifi 与 ebook 模块，然后启动应用。普通 xcodebuild 测试宿主不自动注入该插件；缺插件时 DAC 测试的失败/跳过不能当作真实设备验证。

契约或 Runtime 改动另外运行对应仓库 `swift test` 和 ABI smoke。真实 DAC 回归以用户的实机记录为准；目录整理不增加新的硬件覆盖结论。
