import FoofoilExtensionKit

/// 宿主内部的可选设备增强服务。按已协商的 `audio.device-selection` 选择实现。
protocol ExtensionAudioDeviceServicing {
    func perform(_ request: AudioDeviceServiceRequest) async throws -> AudioDeviceServiceSnapshot
}

enum ExtensionAudioDeviceDiscovery {
    /// 优先 audio 域偏好扩展；否则仅当唯一声明者时选用。多个且无偏好则不用，保留系统输出。
    static func extensionID(
        amongCapable capableIDs: [String],
        preferredExtensionID: String?
    ) -> String? {
        if let preferredExtensionID, capableIDs.contains(preferredExtensionID) {
            return preferredExtensionID
        }
        return capableIDs.count == 1 ? capableIDs[0] : nil
    }
}
