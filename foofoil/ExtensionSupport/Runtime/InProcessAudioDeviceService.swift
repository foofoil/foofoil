import FoofoilExtensionKit

/// 按已协商能力选中的应用级 Runtime 设备服务。
struct InProcessAudioDeviceService: ExtensionAudioDeviceServicing {
    private let performCommand: @Sendable (AudioDeviceServiceRequest) throws -> AudioDeviceServiceSnapshot

    init(performCommand: @escaping @Sendable (AudioDeviceServiceRequest) throws -> AudioDeviceServiceSnapshot) {
        self.performCommand = performCommand
    }

    func perform(_ request: AudioDeviceServiceRequest) async throws -> AudioDeviceServiceSnapshot {
        let performCommand = performCommand
        // ABI 内部仍串行访问 Runtime；设备 I/O 保持离开主线程。
        return try await Task.detached(priority: .userInitiated) {
            try performCommand(request)
        }.value
    }
}
