# S07 原生通信／原文件授权实验

这是可独立移除的技术原型，不是 `foil` CLI，不接入产品窗口、历史、启动恢复或凭证系统。首轮隐藏状态失败已在第二轮修复，见文末。Developer ID 分发验收仍待证书。

## 构建与验证

要求 macOS、Xcode、可用的本地代码签名身份。使用已有证书的 hash，不申请或修改证书：

```sh
security find-identity -v -p codesigning
PROBE_SIGN_IDENTITY='<existing identity hash>' scripts/agent-terminal-prototype/build
python3 scripts/agent-terminal-prototype/verify.py
```

构建启用 Swift 6、`-O`、warnings-as-errors、hardened runtime，并直接使用产品的 `foofoil/foofoil.entitlements`。不会使用 Debug 的网络监听权限，不会回退到 ad-hoc 签名。Apple Development 签名实验不能替代 Developer ID 签名的产品 Release 验收。

输出在被忽略的 `build/agent-terminal-prototype/`：独立 `AgentTerminalProbe.app`、原生 `probe-client`、`results.json`。运行前确认没有手工启动的同名原型；验证脚本只管理这个原型实例，不关闭 foofoil。原型有独立 bundle ID `com.markonce.foofoil.AgentTerminalProbe`。

## 实验内容

- CLI 创建权限为 0700 的临时目录及 0600 的 JSON 信封，以 `NSWorkspace.open` 将信封和原文件交付到指定应用。
- 宿主只读取原文件；响应含大小和 SHA-256，不包含正文。响应原位写回信封，不请求父目录授权。
- CLI 默认最多等候 15 秒；超时不能推断请求未执行。整个调用另受验证脚本 20 秒超时保护。
- 宿主将单个只读安全书签保存在自己的容器中；显式 release 释放自己持有的 scope，quit 后由新进程 restore。**release 测试只证明原型不再持有读取目标，不证明系统已撤回所有通过打开事件授予的隐式访问。**
- 文件读取限制 1 MiB，信封限制 16 KiB。这是隔离实验限制，不是正式协议参数。实验只用文本夹具，不宣称已验证图片或 SVG 解码。
- 验证同路径写入、原子替换、删除后的失败、无空窗、前台应用采样、重复调用的隐藏状态。hiddenAfter 在回调后等待 250 ms 再采样，避免只看回调时的瞬时状态。
- 验证脚本 finally 调用 reset／quit，删除自己创建的源文件、信封和书签；不会删除用户文件或产品数据。生成的二进制及报告留在 build 下供复查。

验证成功才返回 0；任一验收项失败返回 1，工具异常／超时也不会伪装通过。隐藏状态检查必须保持启用，不能通过删测试、忽略退出码、临时取消沙盒或变更产品签名使门槛变绿。

## 2026-10-17 结果

macOS 27.0.1 (26A434)，Xcode 27.1 (27A9275)，arm64，Apple Development / Team RFQ56XLHXJ。严格签名验证通过，现有 Release entitlements 生效。

`verify.py`：12 PASS、1 FAIL，退出码 1。失败项为 `repeated calls preserve app hidden state`。前台采样均为 `com.openai.codex`，不等同于其他应用连续输入、多屏或全屏 Space 验收。

`./package-dmg --sign-only`：退出码 1，`未找到 Developer ID Application 证书。` 未绕过签名或以 Development 证书替代产品分发证书。

协议评估与后续入口见 [实现规格草案](../../docs/agent-terminal-protocol-v1.zh-CN.md)。

## 第二轮修正

保留上文首轮失败证据。后续使用应用启动早期的标准文档事件处理器，加上运行中直接发送的标准 Apple Event，避免普通 AppKit 打开分派；仍保留系统自动沙盒注解。相同构建、签名和权限条件下重新运行 verify.py：**13 PASS、0 FAIL、退出 0**。正式产品与 CLI 已独立接入，见协议文档；该目录仍只是可移除实验，不是正式 CLI。
