# 设备服务能力发现 v1

复用已有 application-scope 能力 `audio.device-selection` 与 `AudioDeviceServiceRequest`，不新增注册框架。消息仍走 `perform_application_command`。

## 发现

宿主在已加载扩展的 Manifest 上做 `CapabilityNegotiator` 协商。声明该能力且版本 ≤ 1、scope 为 application 的扩展视为候选。

## 多个设备服务

1. 用户在 `audio` 偏好域选定的扩展若在候选中，使用它。
2. 否则若只有一个候选，使用它。
3. 否则不选用设备服务，普通 PCM 走系统输出。
4. 未声明该能力的旧 Hi-Fi 仍可通过隔离兼容层按扩展 ID 回退。

`media.transport` 的 `selectDevice` 不是设备服务发现，也不表示该 Provider 使用独占输出。
