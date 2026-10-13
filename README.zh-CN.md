# Video

浮箔的内置视频能力模块，作为独立 Git 项目维护。用户无需安装或启用；宿主打包时决定是否嵌入。

## 构建

```sh
./scripts/build-ffmpeg
swift test
./build-plugin /tmp/video-bundles - release
```

宿主 `./run`、`./package-dmg` 默认包含 Video，`--without-video` 排除它，`--with-video` 显式包含。
首次构建下载并校验 FFmpeg 8.0.1 源码；后续使用本地缓存。生成文件均位于忽略的 `.build` 或临时构建目录。

## 能力与边界

- 本地 MKV、AVI；H.264、HEVC（优先 VideoToolbox）、MPEG-4 ASP/Xvid。
- AAC、AC3、EAC3、DTS/DTS-HD MA、TrueHD、MP3；以 48 kHz 双声道 PCM 经系统默认设备输出，不保留 Atmos 对象或压缩音频直通。
- 音轨、内嵌字幕切换；SRT、ASS 提供独立文字条目，宿主全局样式排版；PGS 提供独立透明图形缓冲。ASS 动画、字体附件尚未实现；外部字幕由宿主管理。
- 有界音频预缓冲、三个 IOSurface 画面缓冲；不复制整片、不转码生成媒体缓存。
- C ABI + JSON 会话协议；宿主只拿 IOSurface ID，播放控制、播放互斥和历史由宿主持有。
- `video-inspect <文件...>` 验证首帧、60 秒定位、逐轨切换、静音播放时钟与暂停。

## 第三方代码

模块自有代码 MIT；静态链接的裁剪版 FFmpeg 为 LGPL-2.1-or-later，许可证随模块打包。未开启 GPL/nonfree 组件。见 `ThirdParty/NOTICE.md`。
