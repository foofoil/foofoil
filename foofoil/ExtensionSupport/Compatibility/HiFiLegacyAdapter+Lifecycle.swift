import FoofoilExtensionKit

extension HiFiLegacyAdapter {
    static func closeSession(_ session: ContentSession, provider: any ContentProvider) async throws {
        // 旧版仅 Hi-Fi 定义了该关闭消息；不能向其他 Provider 发送私有命令。
        guard supports(session) else { return }
        _ = try await provider.perform(commandID: Command.close.rawValue, session: session)
    }
}
