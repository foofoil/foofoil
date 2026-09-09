import FoofoilExtensionKit

/// 宿主内部的可选设备增强服务；公开 ABI 与能力协商将在后续阶段补齐。
protocol ExtensionAudioDeviceServicing {
    func perform(_ request: AudioDeviceServiceRequest) async throws -> AudioDeviceServiceSnapshot
}
