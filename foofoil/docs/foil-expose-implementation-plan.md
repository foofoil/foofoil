# 自建 App Exposé 功能实现计划

状态：计划阶段，尚未实现代码。

## 1. 目标

在 foofoil 的“窗口”菜单中增加“显示所有箔片”菜单项，并绑定快捷键 Ctrl+Option+F。

触发后：

- 覆盖当前所有屏幕，展示本 App 所有浮动箔片窗口对应的历史缩略图。
- 缩略图按网格排列。
- 点击某个缩略图，或按下对应数字/字母快捷键，将该箔片窗口调度到最前。
- 按 Esc 或再次触发菜单项，关闭覆盖层。
- 只管理本 App 自己的窗口。
- 不使用屏幕录制、辅助功能、输入监控或私有 WindowServer API。

## 2. 非目标

- 不处理其他 App 的窗口。
- 不抓取新的屏幕截图，只复用历史记录中已有的缩略图。
- 不替代系统 Mission Control 或系统 App Exposé。
- 不做全局快捷键，只在 foofoil 激活时通过菜单快捷键触发。
- 第一版不支持超过 35 个窗口的键盘快捷选择，超出部分仍可点击选择。

## 3. 现有基础

- 浮动窗口类型为 FloatingWindow，由 FloatingWindowController 管理。
- AppDelegate.windowControllers 持有当前所有浮动窗口控制器。
- 每个 AppState 有稳定的 id，与 HistoryRepository 中的 WindowConfig.id 对应。
- HistoryRepository.config(id:) 可读取历史配置。
- WindowConfig.thumbnailPath 保存历史缩略图 HEIC 路径。
- HistorySearchThumbnailLoader 可按 128 像素解码缩略图，并带有缓存和并发限制。
- 窗口菜单在 AppDelegate+MenuSetup.swift 中动态构建。
- 菜单校验在 AppDelegate+MenuValidation.swift 中处理。
- 用户可见字符串统一放在 Localizable.xcstrings。
- Xcode 使用文件系统同步 source group，新增源文件不需要手动修改 project.pbxproj。

## 4. 总体架构

新增或修改以下部分组成功能：

- FoilExposeShortcut：纯函数，负责索引到数字/字母快捷键的映射。
- FoilExposeItem：覆盖层中一个箔片的快照。
- FoilExposeModel：ObservableObject，保存所有条目和快捷键映射。
- FoilExposePanel：NSPanel 子类，可以成为 key window。
- FoilExposeController：单例控制器，负责收集窗口、展示和关闭覆盖层、处理选择和键盘事件。
- FoilExposeView 与 FoilExposeItemView：SwiftUI 覆盖层界面。
- AppDelegate.showAllFoilsAction：菜单动作入口。
- FoilExposeShortcutTests：快捷键映射的单元测试。

## 5. 数据模型

FoilExposeItem 建议包含：

- id：使用 AppState.id。
- controller：对 FloatingWindowController 的引用。
- screen：收集时窗口所在屏幕，用于分配到对应覆盖层面板。
- title：优先使用历史配置的 historyMenuDisplayName，否则使用“未命名笔记”。
- symbolName：历史配置的 historyMenuSymbolName。
- contentKind：历史配置的 contentKind；缺失时使用 HistoryContentKind.infer。
- thumbnailPath：优先使用历史缩略图路径；图片和 PDF 在缺少缩略图时回退到 imagePath。
- shortcut：当前索引对应的数字或字母；超过 35 时为 nil。
- window：计算属性，返回 controller.window。

FoilExposeModel 建议包含：

- items：[FoilExposeItem]，按屏幕排序后的结果。
- itemsByKey：快捷键到条目的映射。
- onSelect：点击条目回调。
- onDismiss：点击背景或 Esc 时的回调。
- items(for screen:)：返回指定屏幕的条目。

## 6. 快捷键映射

规则如下：

- 索引 0 到 8 映射为 1 到 9。
- 索引 9 到 34 映射为 A 到 Z。
- 索引 35 及以上返回 nil，不显示键盘角标，但仍可点击。
- 按下的键先统一转成大写，再查 itemsByKey。

## 7. 覆盖层创建

每个 NSScreen 创建一个 FoilExposePanel：

- frame 使用 screen.frame，覆盖整个屏幕。
- styleMask 使用 borderless 和 nonactivatingPanel。
- level 使用 screenSaver，确保位于普通窗口之上。
- backgroundColor 使用 clear，由 SwiftUI 绘制半透明背景。
- isOpaque 为 false。
- hasShadow 为 false。
- hidesOnDeactivate 为 false。
- isReleasedWhenClosed 为 false。
- isExcludedFromWindowsMenu 为 true。
- collectionBehavior 包含 canJoinAllSpaces、fullScreenAuxiliary、stationary、ignoresCycle。
- contentView 使用 NSHostingView 承载 FoilExposeView。

展示顺序：

1. 调用 NSApp.activate 激活 foofoil。
2. 所有覆盖层面板 orderFront。
3. 找到鼠标所在屏幕，让对应面板成为 key window。
4. 安装本地键盘事件监听。
5. 监听 NSApplication.didResignActiveNotification，App 失去激活时自动关闭覆盖层。

## 8. 键盘与鼠标交互

键盘：

- 使用 NSEvent.addLocalMonitorForEvents(matching: .keyDown)。
- 不使用全局事件监听，不需要辅助功能或输入监控权限。
- 如果事件带有 Command、Control 或 Option，则放行，让菜单快捷键继续工作。
- Esc 键调用 dismiss。
- 其他无修饰键的按键统一转大写查快捷键映射。
- 命中条目则调用 select；未命中则静默处理，不发出系统提示音。

鼠标：

- 点击缩略图调用 select。
- 点击空白背景调用 dismiss。
- 条目悬停时提供轻微放大和高亮反馈。

关闭覆盖层：

- 移除本地键盘事件监听。
- 移除 didResignActive 观察者。
- 所有面板 orderOut。
- 清空 panels 和 model。

## 9. 选择后的窗口调度

select 流程：

1. 校验 item.window 是否仍然存在。
2. 调用 dismiss 关闭覆盖层。
3. 如果窗口已最小化，调用 deminiaturize。
4. 调用 activateApplication 激活 foofoil。
5. 调用 controller.showWindow(nil)。
6. 调用 window.makeKeyAndOrderFront(nil)。
7. 调用 window.orderFrontRegardless()，作为兜底。

FloatingWindow 已经使用 canJoinAllSpaces 和 fullScreenAuxiliary，因此通常可以直接切到最前。

## 10. 界面设计

FoilExposeView：

- 半透明深色背景。
- 顶部显示标题“显示所有箔片”。
- 标题下显示提示“按数字或字母选择，Esc 退出”。
- 使用 LazyVGrid 自适应列数排列缩略图。
- 当前屏幕没有条目时显示空状态文案。

FoilExposeItemView：

- 缩略图区域优先显示 item.thumbnailPath 对应的图片。
- 没有缩略图时显示 symbolName 图标与标题占位。
- 音视频条目在缩略图上叠加播放或音乐符号。
- 左侧或上方显示快捷键角标。
- 下方显示标题。
- 悬停、按下、可访问性标签遵循现有 HistoryCardView 的交互风格。

## 11. 菜单接入

在 AppDelegate+MenuSetup.swift 的窗口菜单中：

- 在窗口位置菜单项之后增加分隔线。
- 增加“显示所有箔片”菜单项，action 指向 showAllFoilsAction。
- keyEquivalent 为 f。
- keyEquivalentModifierMask 为 control 与 option。
- target 指向 AppDelegate。
- 可选用 rectangle.grid.2x2 作为 SF Symbol。
- 在移动屏幕菜单项之前再加入分隔线。

在 AppDelegate+MenuValidation.swift 中：

- showAllFoilsAction 对应菜单项在 windowControllers 中至少有一个 window 时启用。
- 没有窗口时禁用，但仍保留菜单项可见。

## 12. 本地化

在 Localizable.xcstrings 中增加以下 key，并同时补齐英文和简体中文：

- Show All Foils：显示所有箔片。
- Show All Foils Hint：按数字或字母选择，Esc 退出。
- No Foils on This Screen：此屏幕没有箔片。

现有 Untitled Note 可直接复用。

## 13. 建议文件改动

新增：

- foofoil/App/FoilExposeController.swift
- foofoil/Views/FoilExposeView.swift
- foofoilTests/FoilExposeShortcutTests.swift

修改：

- foofoil/App/AppDelegate+MenuSetup.swift
- foofoil/App/AppDelegate+MenuValidation.swift
- foofoil/Localizable.xcstrings

Xcode 使用文件系统同步 group，因此无需修改 project.pbxproj。

## 14. 测试计划

单元测试：

- 索引 0 到 8 返回 1 到 9。
- 索引 9 返回 A。
- 索引 34 返回 Z。
- 索引 35 返回 nil。
- 负数返回 nil。

构建与集成测试：

- 运行 xcodebuild test -project foofoil.xcodeproj -scheme foofoil -destination 'platform=macOS'。
- 构建通过后运行 ./run 做人工验证。

人工验证清单：

- 窗口菜单出现“显示所有箔片”，快捷键显示为 Ctrl+Option+F。
- 只有一个窗口时可以打开覆盖层。
- 多个窗口时缩略图数量与窗口数量一致。
- 点击缩略图后对应窗口到最前。
- 数字键 1 到 9 可切换对应窗口。
- 字母键 A 到 Z 可切换对应窗口。
- Esc 关闭覆盖层。
- 再次按 Ctrl+Option+F 关闭覆盖层。
- 点击背景关闭覆盖层。
- 切换 App 后覆盖层自动关闭。
- 最小化窗口可以被恢复并到最前。
- 多显示器时覆盖层分别出现在各屏幕，条目按窗口所在屏幕分配。
- 没有历史缩略图时显示类型图标和标题，不崩溃。
- 超过 35 个窗口时，额外窗口仍可点击。
- 浅色和深色外观下可读性正常。
- VoiceOver 可以读出条目标题和快捷键提示。

## 15. 风险与取舍

- screenSaver 层级会覆盖菜单栏和系统 UI。这是临时交互，Esc 可退出；如果产品希望更保守，可降为 floating。
- 多屏时每个屏幕一个面板，键盘监听只有一个，模型共享。
- 历史缩略图可能过期；这是复用历史记录的固有特点，交互中不重新截图。
- 超过 35 个窗口时没有字母可用；第一版保留点击选择，后续可加分页或两段式快捷键。
- 历史数据库读取通常在毫秒级；如果窗口数量很大，可在收集前批量读取 recent 配置，减少单条查询。
- 不引入任何第三方依赖和额外权限。
- 不操作系统窗口，不触碰其他 App，不调用私有 API。

## 16. 验收标准

- 功能严格限制在 foofoil 自己的浮动窗口。
- 无新增 TCC 权限请求。
- 菜单与快捷键可用。
- 点击和键盘选择都能正确前置对应窗口。
- Esc、背景点击、App 切换都能可靠关闭覆盖层。
- 构建无新增警告，相关单元测试通过。
