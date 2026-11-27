# 文档呈现 v1

本文定义 `ContentSession.presentation` 的可选 `document` 形态，用于扩展把自行生成的本地文档交给宿主呈现。它复用 Extension API v1 的 `ContentSession` JSON，不新增 C ABI 字段，也不新增 capability。

## 消息

`SessionPresentation` 新增：

```json
{ "kind": "document", "url": "file:///.../chapter-0000.html#anchor" }
```

| 字段 | 要求 |
| --- | --- |
| `kind` | 固定 `document` |
| `url` | 本机绝对文件 URL，无远端 host、用户名、密码或 query；允许 fragment 表示文档内锚点 |

## 生命周期

- 文件由扩展创建、更新和删除，随活会话生命周期有效；扩展必须保证已发布的 URL 在对应会话关闭前始终可读。
- 文件发布后不可原地修改；换章或换锚点必须使用新文件 URL 或新的 fragment URL。
- 会话关闭后宿主不得再引用旧 URL；临时文件只由扩展负责清理。

## 宿主职责

- 只允许 `file:` URL；拒绝远端 scheme、带 host 的 file URL 与非法 URL，并显示本地化占位。
- 去 fragment 后校验文件存在、为普通文件且非符号链接，并要求其位于宿主进程临时目录之下（in-process 扩展写入该目录）；任何校验失败都不得扩大读权限。
- 使用系统只读文档视图加载，读权限只授予该 HTML 文件本身；文档资源必须由扩展内联，宿主不授权 EPUB 原文件或其他目录。
- 禁用 JavaScript、禁用持久化网站数据；在首次加载前安装资源拦截与导航策略。禁止网络不能只依赖禁用 JavaScript：扩展输出应带 CSP，宿主策略作为纵深防御。
- 只允许当前目标文档及其 fragment 导航；拒绝不同路径、远端 URL、子 frame、重定向与下载，拒绝新窗口。被阻止的链接不得交给外部浏览器打开。
- 相同文件的不同 fragment 更新也按新目标处理；`loadFileURL` 对 fragment 的原生定位行为由宿主实现验证，不可用时至少落在文档顶部。

## 兼容范围

`document` 与更新后的宿主和 extension-kit 同步交付；不承诺旧宿主解码新形态，也不为旧宿主保留兼容层。EPUB 解析规则属于 `ebook` 扩展，不写入本契约。
