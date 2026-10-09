# Apple Music 初版接入

实现位于主项目的 `foofoil/AppleMusic/`，使用原生 MusicKit，不经过 Hi-Fi 的文件解码或设备输出链路。

## 开发环境配置

1. 在 Apple Developer 的 Certificates, Identifiers & Profiles 中，打开浮箔当前 Bundle ID 对应的 App ID。
2. 在 App Services 中启用 MusicKit。应用的 Bundle ID 必须与该 App ID 一致。
3. 应用已声明并本地化 NSAppleMusicUsageDescription。首次选择授权入口时，调用 MusicAuthorization.request()。
4. 在 Mac 的音乐 App 登录账号。播放订阅内容需要有效播放资格；用户 token 与开发者 token 由原生 MusicKit 自动管理。

本次实现没有修改开发者后台配置，也没有增加私钥、手动 token 或服务器。

参考：<https://developer.apple.com/documentation/musickit/using-automatic-token-generation-for-apple-music-api>

## 验证入口

- 文件 → 打开 Apple Music 资料库：授权界面；授权后浏览专辑、歌曲、歌单，分页载入。搜索覆盖自己的资料库。
- 专辑／歌单详情：播放完整队列，或从指定曲目开始。
- 快速打开与总览 `/` 搜索：在设置 → 通用 → 搜索中启用 Apple Music 搜索后，与历史及 Spotlight 文件并行查询。用户文件在前，音乐按专辑、歌曲、歌单分组；各组先显示 6 个，每次更多增加 18 个，整个结果区最多展示 60 个。可筛选用户文件、专辑或歌曲，确认仍有匹配时提示细化关键词。
- 音乐浮窗：复用音频呈现层，使用通用音频控制条和通用侧边列表。控制条提供进度、暂停及四种播放模式；通用导航命令与列表点击负责选曲。列表支持当前项播放标记、悬停显示、始终显示和查找定位。

## 初版边界

- 复用一个 Apple Music 浮窗及 MusicKit 的共享播放器；新选曲替换共享队列。关闭最后一个音乐浮窗停止播放。
- 音乐内容保存到历史，退出后可恢复。历史保存资料库身份并缓存封面缩略图，重开时通过 MusicKit 读取当前条目；来源缺失或授权失效时保留历史并提供重试。
- 默认无边框，可通过视图菜单、右键菜单和通用边框快捷键切换；历史保留边框选择。Apple Music 在历史及总览中使用 `music.pages.fill` 区别于其他音频。
- 不提供音质切换、独占输出、指定 DAC 或音源采样率匹配。
- 本地导入歌曲也由 MusicKit 播放，暂不转换到本地／Hi-Fi 引擎。
- 没有授权账号的实测之前，不保证上传／匹配歌曲、离线及各地区账号的实际播放表现。
- 自动测试覆盖搜索权限、取消、键盘选择、结果上限、历史持久化、边框恢复和封面缓存。已用实际资料库验证专辑播放、通用控制条、历史重开、边框切换及封面显示；离线和地区差异仍需分别验证。
