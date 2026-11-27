import Foundation

public enum SessionLifecycleOperation: String, Codable, Sendable {
    case close
    case restore
}

/// 当前曲目 ID 对宿主不透明；位置以秒计。恢复不携带旧会话 UUID 或播放意图。
public struct PlaybackRestorationState: Codable, Equatable, Sendable {
    public var currentItemID: String?
    public var position: TimeInterval?

    public init(currentItemID: String? = nil, position: TimeInterval? = nil) {
        self.currentItemID = currentItemID
        self.position = position
    }
}

/// 通过 ABI v1 perform_command 传输；仅在 session.lifecycle v1 激活时发送。
public struct SessionLifecycleRequest: Codable, Equatable, Sendable {
    public static let commandIdentifier = "session.lifecycle"
    public let commandID: String
    public let contractVersion: UInt32
    public let operation: SessionLifecycleOperation
    public let session: ContentSession
    public let restoration: PlaybackRestorationState?

    public init(
        operation: SessionLifecycleOperation, session: ContentSession,
        restoration: PlaybackRestorationState? = nil, contractVersion: UInt32 = 1
    ) {
        commandID = Self.commandIdentifier
        self.contractVersion = contractVersion
        self.operation = operation
        self.session = session
        self.restoration = restoration
    }

    public static func isSupported(by session: ContentSession) -> Bool {
        session.capabilities.contains {
            $0.declaration.id == ExtensionCapabilityIdentifier.sessionLifecycle
                && $0.declaration.contractVersion == 1
                && $0.declaration.scope == .session
                && $0.state == .active
        }
    }

    public func validate() throws {
        guard commandID == Self.commandIdentifier, contractVersion == 1 else {
            throw SessionLifecycleError.unsupportedContract
        }
        guard Self.isSupported(by: session) else { throw SessionLifecycleError.missingCapability }
        switch operation {
        case .close:
            guard restoration == nil else { throw SessionLifecycleError.invalidRestoration }
        case .restore:
            guard let restoration,
                  restoration.currentItemID.map({ !$0.isEmpty }) ?? true,
                  restoration.position.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                throw SessionLifecycleError.invalidRestoration
            }
        }
    }
}

public enum SessionLifecycleError: Error, Equatable {
    case unsupportedContract
    case missingCapability
    case invalidRestoration
}
