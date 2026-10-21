# 终端控制 P0a：沙盒、Socket 与 PTY 前置原型

此目录是独立、可移除的技术实验，不接入产品窗口、历史、现有 Agent 协议或 CLI。原型已实现，但正式集成的可行性门槛**未通过**。

## 构建与复现

在仓库根目录执行，指定本机已有的有效签名身份，不申请证书：

```sh
security find-identity -v -p codesigning
PROBE_SIGN_IDENTITY='<existing identity hash>' scripts/terminal-control-prototype/build
python3 scripts/terminal-control-prototype/verify.py
```

需要 macOS、Xcode、Python 3 和已有开发签名身份。Swift 使用 Swift 6、优化和 warnings-as-errors；C 使用优化及 `-Wall -Wextra -Werror`。构建失败必须先修复，不使用旧产物继续验收。

产物和逐项 JSON 证据位于被忽略的 `build/terminal-control-prototype/`，不提交生成的二进制或报告。`verify.py` 遇到工具异常也保留失败报告，任一门槛失败返回 1，不把预期中的沙盒失败当成功。

## 实验边界

- 宿主是 `com.markonce.foofoil.TerminalControlProbe`，直接使用2026-10-20 切换前产品的 **Release entitlements 快照**（`host.entitlements`），开启 App Sandbox、hardened runtime，使用现有 Apple Development 身份签名并执行严格签名校验。没有增加主应用权限，也没有修改 Debug/Release 配置。
- 宿主通过既有原型的标准文档事件收发 JSON 信封、显式交付原文件/目录并保存一个只读安全书签。该协议只用于实验，不是产品接口。
- Socket 在宿主容器下本次生成的短路径目录内创建，目录 0700、Socket 0600；外部 Python 客户端实际连接，宿主 `getpeereid` 校验 UID 后发送常量。监听和收发不依赖 Debug 的 network.server entitlement。
- `pty-probe` 为嵌入的签名 C helper，使用 `app-sandbox + inherit` 权限，继承宿主沙盒。单线程 helper 使用 `forkpty`、`tcsetpgrp`、`execv`，运行无用户启动脚本的交互式 zsh/bash；文件路径通过位置参数传入，不拼入脚本。
- helper 只运行常量检查脚本或目标程序的 `--version`，设 5 秒上限及输出上限，退出时清理自己创建的会话进程组并回收直接子进程。宿主中的同步等待只用于此有硬上限的独立实验，不能复制到产品主线程。
- 同一 C 源码另建无沙盒、已签名的 `pty-baseline`，用于区分代码缺陷与沙盒限制。`fixture-tool` 是本目录源码生成、已签名的独立版本输出程序，不依赖真实工具链。
- 验收只操作自己在 build 下创建的源文件、目录、Socket、信封和书签。finally 释放授权、删除原型书签、关闭 Socket、退出原型并删除夹具；保留构建产物/报告。不关闭 foofoil，不读取用户 SSH 私钥、配置或 token。
- Socket 检查只证明本机同用户连接和权限模式；没有运行其他 macOS 用户的客户端，不把模式检查描述为跨用户实测。隐藏/前台状态只在采样时观察，不代表连续输入、多屏或 Space 验收。

## 2026-10-20 结果

环境：macOS 27.0.1 (26A434)、Xcode 27.1 (27A9275)、arm64，Apple Development 签名。构建及严格签名校验通过。

完整验证：**24 项，21 PASS、3 FAIL，退出码 1**。

| 能力 | 实测 |
| --- | --- |
| Release 沙盒内绑定/监听 Unix Socket | 通过 |
| 外部同用户客户端连接、获取回复及对端 UID 检查 | 通过 |
| 目录 0700、Socket 0600 | 通过 |
| 路径字符串不授予文件读取能力 | 通过，读取拒绝 |
| 显式文件交付及新进程书签恢复 | 通过 |
| PTY 连接交互式 Shell、isatty | 通过，但不足以判定完整终端可用 |
| 工作目录进入及显式目录交付后的写入 | 通过；仅交付单个文件时不能写其父目录 |
| zsh 的终端前台进程组设置 | **失败：PGRP_DENIED / operation not permitted** |
| bash 的终端前台进程组设置 | **失败：PGRP_DENIED** |
| 沙盒 Shell 执行已显式交付的签名 fixture-tool | **失败：operation not permitted，退出 127** |
| 同一 PTY 代码的非沙盒基线 | zsh/bash 前台进程组与外部签名工具执行均通过 |
| 隐藏状态下重复控制请求 | 采样通过 |

另有人工诊断：本机已安装的 OpenCode 执行 `--version` 也返回 operation not permitted / 127。该观察不是自动验收夹具；自动验证使用自建工具复现同类阻塞，避免依赖开发者的安装环境。

首轮仅检查 PTY 的 14 项全部通过，后续增加前台进程组、目录写入、外部程序及非沙盒基线后发现上述阻塞。因此不能用首轮结果认定 P0a 全部通过，也不能据此承诺 SSH/Vim/OpenCode 已可用。

## 结论与待验证路线

当前“主应用沙盒内直接持有 PTY 并执行工具”的具体实现没有通过前置门槛。证据仅针对本次实现与权限组合，不宣称已穷尽所有 macOS 终端架构。

建议下一轮先验证**独立启动、非沙盒的终端 helper**：主应用保持沙盒和内置终端视图，helper 只在会话存在时运行，持有 PTY；不建常驻守护进程、第二套历史数据库或公开通用 exec API。独立启动方式、主应用退出后的回收、输入/resize 协议、工具链与 SSH Agent 访问、签名和分发均需新原型证明，不能把同样由沙盒宿主直接 spawn 的继承型 helper 当作解决方案。

另一路线是取消主应用沙盒；这影响整个应用的安全和分发边界，不能作为原型失败后的隐式改动。技术路线确认前，不接入产品控制服务或终端引擎。设计入口见 [终端箔设计](../../docs/foofoil-terminal-control-design.zh-CN.md)。

尚未验收：独立 helper、真实 SSH/Agent、Vim/OpenCode TUI、输入法、resize、交互/登录启动脚本、Developer ID、公证、Gatekeeper、其他用户及干净机器。Apple Development 独立原型不替代产品分发验收。

## 后续产品决策

2026-10-20 用户确认仅站外发行，取消主应用沙盒，不迁移旧容器数据。此原型冻结原沙盒条件，仅保留历史证据，不再作为当前非沙盒产品的阻塞项。正式实现直接在主应用管理 PTY，不增加独立非沙盒 helper。
