import FoofoilExtensionKit

extension HiFiLegacyAdapter {
    static func perform(
        mediaAction: MediaPlaybackAction, session: ContentSession, provider: any ContentProvider
    ) async throws -> ContentSession {
        guard supports(session) else { throw ContentProviderError.unsupportedRequest }
        try mediaAction.validate()
        var requested = session
        if case .seek(let position) = mediaAction {
            guard requested.mediaPlayback?.isSeekable == true else { throw MediaTransportError.invalidAction }
            requested.mediaPlayback?.position = position
        }
        return try await provider.perform(commandID: commandID(for: mediaAction), session: requested)
    }

    /// 旧插件的菜单仍贡献私有命令；只在这一入口翻译为宿主媒体意图。
    static func mediaAction(for commandID: String, in session: ContentSession) -> MediaPlaybackAction? {
        guard supports(session) else { return nil }
        if let id = deviceID(in: commandID) { return .selectDevice(id) }
        switch Command(rawValue: commandID) {
        case .play: return .play
        case .pause: return .pause
        case .previous: return .previous
        case .next: return .next
        case .status: return .refresh
        case .seek: return session.mediaPlayback.map { .seek($0.position) }
        default: return nil
        }
    }
}
