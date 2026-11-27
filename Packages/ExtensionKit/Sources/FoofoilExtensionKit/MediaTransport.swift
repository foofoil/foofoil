import Foundation

public enum MediaPlaybackActionKind: String, Codable, Equatable, Sendable, CaseIterable {
    case play, pause, previous, next, refresh, seek, selectDevice, selectSystemDefault, setVolume, setSubtitleDelay
}

public enum MediaPlaybackAction: Equatable, Sendable, Codable {
    case play, pause, previous, next, refresh, selectSystemDefault
    case setSubtitleDelay(Double)
    case setVolume(Double)
    case seek(Double)
    case selectDevice(String)

    public var kind: MediaPlaybackActionKind {
        switch self {
        case .play: .play
        case .pause: .pause
        case .previous: .previous
        case .next: .next
        case .refresh: .refresh
        case .selectSystemDefault: .selectSystemDefault
        case .setSubtitleDelay: .setSubtitleDelay
        case .setVolume: .setVolume
        case .seek: .seek
        case .selectDevice: .selectDevice
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, position, deviceID, volume, delay }
    private typealias Kind = MediaPlaybackActionKind

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let position = try values.decodeIfPresent(Double.self, forKey: .position)
        let deviceID = try values.decodeIfPresent(String.self, forKey: .deviceID)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .play: self = .play
        case .pause: self = .pause
        case .previous: self = .previous
        case .next: self = .next
        case .refresh: self = .refresh
        case .selectSystemDefault: self = .selectSystemDefault
        case .setSubtitleDelay:
            self = .setSubtitleDelay(try values.decode(Double.self, forKey: .delay))
        case .setVolume:
            self = .setVolume(try values.decode(Double.self, forKey: .volume))
        case .seek:
            guard let position else { throw MediaTransportError.invalidAction }
            self = .seek(position)
        case .selectDevice:
            guard let deviceID else { throw MediaTransportError.invalidAction }
            self = .selectDevice(deviceID)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        let kind: Kind
        switch self {
        case .play: kind = .play
        case .pause: kind = .pause
        case .previous: kind = .previous
        case .next: kind = .next
        case .refresh: kind = .refresh
        case .selectSystemDefault: kind = .selectSystemDefault
        case .setSubtitleDelay(let delay):
            kind = .setSubtitleDelay
            try values.encode(delay, forKey: .delay)
        case .setVolume(let volume):
            kind = .setVolume
            try values.encode(volume, forKey: .volume)
        case .seek(let position):
            kind = .seek
            try values.encode(position, forKey: .position)
        case .selectDevice(let id):
            kind = .selectDevice
            try values.encode(id, forKey: .deviceID)
        }
        try values.encode(kind, forKey: .kind)
    }

    public func validate() throws {
        switch self {
        case .setSubtitleDelay(let delay):
            guard delay.isFinite && (-120...120).contains(delay) else { throw MediaTransportError.invalidAction }
        case .setVolume(let volume):
            guard volume.isFinite && (0...1).contains(volume) else { throw MediaTransportError.invalidAction }
        case .seek(let position):
            guard position.isFinite && position >= 0 else { throw MediaTransportError.invalidAction }
        case .selectDevice(let id):
            guard !id.isEmpty else { throw MediaTransportError.invalidAction }
        default: break
        }
    }
}

public struct MediaPlaybackRequest: Codable, Equatable, Sendable {
    public static let commandIdentifier = "media.transport"
    public let commandID: String
    public let contractVersion: UInt32
    public let action: MediaPlaybackAction
    public let session: ContentSession

    public init(action: MediaPlaybackAction, session: ContentSession, contractVersion: UInt32 = 1) {
        commandID = Self.commandIdentifier
        self.contractVersion = contractVersion
        self.action = action
        self.session = session
    }

    public static func isSupported(by session: ContentSession) -> Bool {
        session.capabilities.contains {
            $0.declaration.id == ExtensionCapabilityIdentifier.mediaTransport
                && $0.declaration.contractVersion == 1 && $0.declaration.scope == .session && $0.state == .active
        }
    }

    public func validate() throws {
        guard commandID == Self.commandIdentifier, contractVersion == 1 else { throw MediaTransportError.unsupportedContract }
        guard Self.isSupported(by: session) else { throw MediaTransportError.missingCapability }
        try action.validate()
        if case .seek = action, session.mediaPlayback?.isSeekable != true { throw MediaTransportError.invalidAction }
        if let available = session.mediaPlayback?.availableActions, !available.contains(action.kind) {
            throw MediaTransportError.actionUnavailable
        }
    }
}

public enum MediaTransportError: Error, Equatable {
    case unsupportedContract, missingCapability, invalidAction, actionUnavailable
}
