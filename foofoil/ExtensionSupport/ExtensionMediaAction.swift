import FoofoilExtensionKit

/// 宿主界面直接使用公共媒体动作；旧命令仅在兼容层编码。
typealias ExtensionMediaAction = MediaPlaybackAction

enum ExtensionSessionOperation {
    case media(MediaPlaybackAction)
    case command(String)

    var mediaAction: MediaPlaybackAction? {
        if case .media(let action) = self { return action }
        return nil
    }

    var selectedDeviceID: String? {
        if case .selectDevice(let id) = mediaAction { return id }
        return nil
    }

    func perform(in session: ContentSession) async throws -> ContentSession {
        switch self {
        case .media(let action): try await ExtensionHost.shared.perform(mediaAction: action, in: session)
        case .command(let id): try await ExtensionHost.shared.perform(commandID: id, in: session)
        }
    }
}
