import FoofoilExtensionKit

/// 固定选择旧 Hi-Fi Runtime 的规则只保留在兼容层。
extension HiFiLegacyAdapter {
    static func audioDeviceService(
        in runtimes: [String: InProcessExtensionInterface]
    ) -> (any ExtensionAudioDeviceServicing)? {
        guard let runtime = runtimes[extensionID] else { return nil }
        return HiFiLegacyAudioDeviceService { request in
            try runtime.performApplicationCommand(request)
        }
    }
}

struct HiFiLegacyAudioDeviceService: ExtensionAudioDeviceServicing {
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
