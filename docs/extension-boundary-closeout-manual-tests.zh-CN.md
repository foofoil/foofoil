# 扩展边界收尾手动验证步骤

日期：2026-09-11  
适用范围：收尾阶段 3、4、6 的实机/界面手动验证；自动测试与 ABI smoke 不替代本文。  
依据：[评审终稿](extension-boundary-refactor-review-final.zh-CN.md) §7.3 与[收尾 checklist](extension-boundary-refactor-closeout-checklist.zh-CN.md)。

## 通用准备

1. 构建并启动（注入 hifi 开发插件）：
   ```sh
   cd foofoil && ./run
   ```
2. 记录：foofoil / extension-kit / hifi 提交号、macOS 版本、DAC 型号或 UID（`cd ../hifi && swift run hifi-inspect --devices`）。
3. 准备文件：DSF/DFF、SACD ISO（如有）、普通 PCM（wav/flac/mp3，44.1/48/96 kHz）。
4. 可选观察日志：
   ```sh
   log stream --level debug --predicate 'process == "foofoil"' --style compact
   ```
   关键日志：`exclusive prepared`、`exclusive prepare failed`、`close release failed`、`engine reconfigured`、`stalled`。
5. 结果逐项记录，附设备 UID、文件类型/采样率与证据（截图或日志片段）。

## 阶段 3：关闭与独占交接（2026-09-10 用户复验通过，保留记录）

1. **系统默认输出**：选“跟随系统默认输出”，播放 PCM、暂停、切换内容。预期不参与独占仲裁、无错误提示。
2. **同 DAC 双向交接**：PCM → DSD、DSD → PCM，并快速交替 5–10 次。预期同一时刻只有一个输出持有 DAC，旧输出先释放再启动新输出，无“无法释放独占输出”提示。
3. **设备失效恢复**：播放中拔出 DAC → 停止并报错；重新插入后可恢复；设备被其他应用占用时独占失败有提示且不静默进入；切换到另一台 DAC 正常。
4. **关窗/退出释放**：暂停后关窗、播放中 `⌘Q`、播放中关窗。预期 hog 归还、采样率恢复、其他应用可立即占用。
5. **回归（已修复）**：跟随系统默认输出时在 Audio MIDI Setup 改采样率，进度应从原位继续、UI 与播放状态一致，不得卡在播放态。

## 阶段 4：菜单、动作状态与 P0 删除（待实机复验）

提交基线：foofoil `1e744ca`、hifi `d8fb45b`、extension-kit `3b63bb5`。

1. **扩展菜单不再包含旧 hifi 命令**
   - 用 hifi 打开 DSF/DFF，出现音频覆盖层。
   - 点菜单栏 **Extension**。
   - 预期：菜单隐藏（`commands` 为空），或只含其他扩展真正自定义的命令；不得出现 Play/Pause/Previous/Next/Output Device/具体 DAC 名等旧项。
   - 同时确认音频覆盖层传输控件（播放/暂停、上一首/下一首、进度条）可用。
2. **设备菜单仍可切换**
   - 点击覆盖层右上角设备状态（`hifispeaker.2` + 设备名）。
   - 预期：列出连接的兼容 DAC，当前项勾选；断开/不兼容项禁用；选择另一台后声音与 Audio MIDI Setup 输出都切换。
3. **媒体键仍生效**
   - 让音频窗口为最前窗口，按播放/暂停、下一首、上一首。
   - 预期：与 UI 同步；多曲目切换正确，单曲不误切。
4. **无 hifi 时普通 PCM 仍可播放**
   - 方式 A（真正无插件）：
     ```sh
     rm -rf foofoil/build/Build/Products/Debug/foofoil.app/Contents/PlugIns/Hi-Fi.foofoilextension
     open -n foofoil/build/Build/Products/Debug/foofoil.app
     ```
   - 方式 B：扩展管理器禁用/移除 hifi。
   - 方式 C：hifi 存在时直接播放 wav/flac/mp3（hifi 只声明 DSD/SACD）。
   - 预期：正常出声，传输控件与进度正常，系统默认与独占输出均可用。

## 阶段 6：最终集成手动回归（摘自评审 §7.3）

- 普通 PCM 系统输出与独占输出。
- 同一 DAC 的 PCM → DSD、DSD → PCM 及快速交替。
- DSF、DFF、SACD ISO 的播放、暂停、定位、切曲与后继播放。
- 宿主列表删除、裁剪、重排后的实际续播；容器曲目激活与通用容器呈现。
- 设备拔出、重接、忙碌、切设备、关窗、退出后的资源释放。
- P0 清理后扩展菜单、媒体键、设备菜单行为。
- PCM 独立文件同采样率连播、CUE 首次播放听感；覆盖 44.1 kHz 单/双声道。

## 记录模板

```text
阶段 / 日期 / 执行者：
foofoil / hifi / extension-kit 提交：
设备型号或 UID / macOS：
场景与预期：
实际操作与结果：
证据（截图/日志路径）：
未验证范围 / 风险：
结论：
```
