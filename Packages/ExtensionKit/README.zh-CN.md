# foofoil extension-kit

[foofoil](https://github.com/foofoil/foofoil) 的内部开发模块契约。

本仓库是 Extension API v1 的独立来源：稳定 C ABI、Manifest Schema、capability 标识、Content Request / Session 值类型、导航与媒体契约、兼容性 fixture 以及契约测试。它支持内部模块的独立开发与集成测试。扩展/插件仅是开发手段；最终产品将这些能力作为浮箔自身功能交付，不提供单独安装或更新插件的流程。

加载与界面由 foofoil 持有。Hi-Fi 和 EPUB 实现位于兄弟仓库，由应用构建与分发脚本统一嵌入。现有安装和 Registry 代码属于遗留基础设施，不代表产品分发策略。

## 本包提供的内容

- `FoofoilExtensionABI`：带版本的 C 函数表头文件（`foofoil_extension_create`）
- `FoofoilExtensionKit`：Manifest、`ContentRequest`、`ContentSession`、capability、导航贡献和媒体播放快照的 Swift 值类型与校验器
- Manifest JSON Schema 与兼容性 fixture
- 编码、校验和 API 协商的契约测试

当前内部二进制边界是 C ABI 和 JSON 值消息。Swift protocol、SwiftUI View 和进程内对象不属于模块间共享 API。

## 系统要求

- macOS 15 或更高版本
- 支持所配置 macOS SDK 的 Swift 6 / Xcode

## 在开发模块中使用

将本包作为兄弟目录检出：

```swift
dependencies: [
    .package(path: "../extension-kit")
]
```

然后在 target 中依赖 `FoofoilExtensionKit` 和/或 `FoofoilExtensionABI`。扩展也可以只使用 C ABI 与 JSON 消息，而不导入 Swift 模块。

`.foofoilextension` 包结构如下：

```text
Hi-Fi.foofoilextension
└── Contents
    ├── Info.plist
    ├── MacOS/
    │   └── <runtime>
    └── Resources
        └── ExtensionManifest.json
```

Manifest Schema 见 `Sources/FoofoilExtensionKit/Resources/ExtensionManifest.schema.json`。

## 构建与测试

```sh
swift test
```

## 相关仓库

| 仓库 | 职责 |
| --- | --- |
| [foofoil](https://github.com/foofoil/foofoil) | macOS 应用、模块集成与统一分发 |
| [hifi](https://github.com/foofoil/hifi) | foofoil 的 Hi-Fi 音频模块 |

[English](README.md)

## 许可证

extension-kit 使用 [MIT License](LICENSE)，版权所有 © 2026 北京记忆视界科技有限公司。
