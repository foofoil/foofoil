import Foundation

/// 导航贡献的声明不等于支持动作消息；必须另外协商 ui.navigator-actions v1。
public struct NavigatorActionRequest: Codable, Equatable, Sendable {
    public static let commandIdentifier = "ui.navigator.action"
    public let commandID: String
    public let contractVersion: UInt32
    public let action: NavigatorAction
    public let session: ContentSession

    public init(action: NavigatorAction, session: ContentSession, contractVersion: UInt32 = 1) {
        commandID = Self.commandIdentifier
        self.contractVersion = contractVersion
        self.action = action
        self.session = session
    }

    public static func isSupported(by session: ContentSession) -> Bool {
        session.capabilities.contains {
            $0.declaration.id == ExtensionCapabilityIdentifier.navigatorActions
                && $0.declaration.contractVersion == 1 && $0.declaration.scope == .presentation && $0.state == .active
        }
    }

    public func validate() throws {
        guard commandID == Self.commandIdentifier, contractVersion == 1 else { throw MediaTransportError.unsupportedContract }
        guard Self.isSupported(by: session) else { throw MediaTransportError.missingCapability }
        guard let contribution = session.navigatorContributions.first(where: { $0.id == action.contributionID }) else {
            throw NavigatorContributionError.invalidAction(action.contributionID)
        }
        try NavigatorContributionValidator.validate(action, in: contribution)
    }
}
