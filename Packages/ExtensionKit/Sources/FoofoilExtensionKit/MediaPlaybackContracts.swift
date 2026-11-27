//  MediaPlaybackContracts.swift
//  FoofoilExtensionKit

import Foundation

public enum ExtensionMediaPlaybackState: String, Codable, Sendable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case stopped
    case failed
}

public enum ExtensionMediaRepeatMode: String, Codable, Sendable {
    case off
    case all
    case one
}

public struct MediaPlaybackSnapshot: Codable, Equatable, Sendable {
    public var state: ExtensionMediaPlaybackState
    public var position: TimeInterval
    public var duration: TimeInterval?
    public var isSeekable: Bool
    public var volume: Double?
    public var failureMessage: String?
    /// 缺省时由状态、isSeekable 与队列长度推导；显式列出时宿主必须遵守。
    public var availableActions: [MediaPlaybackActionKind]?

    public init(
        state: ExtensionMediaPlaybackState = .idle,
        position: TimeInterval = 0,
        duration: TimeInterval? = nil,
        isSeekable: Bool = false,
        volume: Double? = nil,
        failureMessage: String? = nil,
        availableActions: [MediaPlaybackActionKind]? = nil
    ) {
        self.state = state
        self.position = position
        self.duration = duration
        self.isSeekable = isSeekable
        self.volume = volume
        self.failureMessage = failureMessage
        self.availableActions = availableActions
    }

    public func allows(_ kind: MediaPlaybackActionKind, queueItemCount: Int = 0) -> Bool {
        if let availableActions {
            return availableActions.contains(kind)
        }
        switch kind {
        case .play: return state != .playing && state != .loading
        case .pause: return state == .playing
        case .seek: return isSeekable
        case .previous, .next: return queueItemCount > 1
        case .refresh, .selectDevice: return true
        case .setSubtitleDelay: return false
        case .setVolume: return volume != nil
        case .selectSystemDefault: return false
        }
    }
}

public struct MediaPlaybackQueueItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var subtitle: String?
    public var duration: TimeInterval?
    public var symbolName: String?
    public var isPlayable: Bool

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        duration: TimeInterval? = nil,
        symbolName: String? = nil,
        isPlayable: Bool = true
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.duration = duration
        self.symbolName = symbolName
        self.isPlayable = isPlayable
    }
}

public struct MediaPlaybackQueueSnapshot: Codable, Equatable, Sendable {
    public let contractVersion: UInt32
    public var items: [MediaPlaybackQueueItem]
    public var currentItemID: String?
    public var repeatMode: ExtensionMediaRepeatMode
    public var isShuffled: Bool
    public var revision: UInt64
    /// 容器专辑标题；外部文件队列为空。
    public var title: String?

    public init(
        contractVersion: UInt32 = 1,
        items: [MediaPlaybackQueueItem],
        currentItemID: String? = nil,
        repeatMode: ExtensionMediaRepeatMode = .off,
        isShuffled: Bool = false,
        revision: UInt64 = 0,
        title: String? = nil
    ) {
        self.contractVersion = contractVersion
        self.items = items
        self.currentItemID = currentItemID
        self.repeatMode = repeatMode
        self.isShuffled = isShuffled
        self.revision = revision
        self.title = title
    }
}

public enum DSDOutputPolicy: String, Codable, Sendable {
    case automatic
    case preferDoP
    case convertToPCM
}

public enum AudioOutputTransport: String, Codable, Sendable {
    case system
    case pcm
    case dop
}

public struct AudioOutputDeviceDescriptor: Codable, Equatable, Identifiable, Sendable {
    /// 使用 CoreAudio AudioDeviceUID；设备重连时不能依赖易变的 AudioObjectID。
    public let id: String
    public var displayName: String
    public var isSystemDefault: Bool
    public var isConnected: Bool
    /// 设备是否可用于当前会话内容（如当前 DSD 速率）。缺省 true；宿主据此禁用不可选设备，
    /// 但真正的切换校验仍由扩展在 selectDevice 时执行。
    public var isCompatible: Bool
    public var hasHardwareVolume: Bool
    public var supportedDoPRates: [Int]
    /// 设备是否公开可写 Hog Mode；真正取得独占仍须在播放前尝试。
    public var supportsExclusiveMode: Bool
    /// 设备公开的 PCM nominal sample rate。空数组表示扩展未提供该能力信息。
    public var supportedPCMSampleRates: [Double]

    public init(
        id: String,
        displayName: String,
        isSystemDefault: Bool = false,
        isConnected: Bool = true,
        isCompatible: Bool = true,
        hasHardwareVolume: Bool = false,
        supportedDoPRates: [Int] = [],
        supportsExclusiveMode: Bool = false,
        supportedPCMSampleRates: [Double] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.isSystemDefault = isSystemDefault
        self.isConnected = isConnected
        self.isCompatible = isCompatible
        self.hasHardwareVolume = hasHardwareVolume
        self.supportedDoPRates = supportedDoPRates
        self.supportsExclusiveMode = supportsExclusiveMode
        self.supportedPCMSampleRates = supportedPCMSampleRates
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, isSystemDefault, isConnected, isCompatible, hasHardwareVolume, supportedDoPRates
        case supportsExclusiveMode, supportedPCMSampleRates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            displayName: try container.decode(String.self, forKey: .displayName),
            isSystemDefault: try container.decodeIfPresent(Bool.self, forKey: .isSystemDefault) ?? false,
            isConnected: try container.decodeIfPresent(Bool.self, forKey: .isConnected) ?? true,
            isCompatible: try container.decodeIfPresent(Bool.self, forKey: .isCompatible) ?? true,
            hasHardwareVolume: try container.decodeIfPresent(Bool.self, forKey: .hasHardwareVolume) ?? false,
            supportedDoPRates: try container.decodeIfPresent([Int].self, forKey: .supportedDoPRates) ?? [],
            supportsExclusiveMode: try container.decodeIfPresent(Bool.self, forKey: .supportsExclusiveMode) ?? false,
            supportedPCMSampleRates: try container.decodeIfPresent([Double].self, forKey: .supportedPCMSampleRates) ?? []
        )
    }
}

public enum PCMOutputRouteMode: String, Codable, Sendable {
    case systemDefault
    case exclusiveDevice
}

public enum AudioDeviceServiceCommand: String, Codable, Sendable {
    case snapshot
    case selectSystemDefault
    case prepareExclusivePCM
    case releasePCM
    case releaseAllPCM
}

/// application-scope 设备服务请求。clientID 防止旧箔释放新箔刚取得的独占 lease。
public struct AudioDeviceServiceRequest: Codable, Equatable, Sendable {
    public let command: AudioDeviceServiceCommand
    public let clientID: UUID
    public var selectedDeviceID: String?
    public var sourceSampleRate: Double?
    public var channelCount: Int?

    /// 多个声明时由宿主按 audio 域偏好选择；无偏好且多于一个则不选用。
    public static func isDeclared(in declarations: [ExtensionCapabilityDeclaration]) -> Bool {
        CapabilityNegotiator.negotiate(declarations).accepted.contains {
            $0.declaration.id == ExtensionCapabilityIdentifier.deviceSelector
        }
    }

    public init(
        command: AudioDeviceServiceCommand,
        clientID: UUID,
        selectedDeviceID: String? = nil,
        sourceSampleRate: Double? = nil,
        channelCount: Int? = nil
    ) {
        self.command = command
        self.clientID = clientID
        self.selectedDeviceID = selectedDeviceID
        self.sourceSampleRate = sourceSampleRate
        self.channelCount = channelCount
    }
}

/// Hi-Fi application capability 的低频状态；实时 PCM 数据仍由宿主 AVAudioEngine 直接输出。
public struct AudioDeviceServiceSnapshot: Codable, Equatable, Sendable {
    public let contractVersion: UInt32
    public var devices: [AudioOutputDeviceDescriptor]
    public var pcmRouteMode: PCMOutputRouteMode
    public var selectedPCMDeviceID: String?
    public var activeClientID: UUID?
    public var activeDeviceID: String?
    public var activeSampleRate: Double?
    public var sourceSampleRate: Double?
    public var sampleRateMatched: Bool?
    public var statusDescription: String?
    public var failureMessage: String?
    public var revision: UInt64

    public init(
        contractVersion: UInt32 = 1,
        devices: [AudioOutputDeviceDescriptor],
        pcmRouteMode: PCMOutputRouteMode = .systemDefault,
        selectedPCMDeviceID: String? = nil,
        activeClientID: UUID? = nil,
        activeDeviceID: String? = nil,
        activeSampleRate: Double? = nil,
        sourceSampleRate: Double? = nil,
        sampleRateMatched: Bool? = nil,
        statusDescription: String? = nil,
        failureMessage: String? = nil,
        revision: UInt64 = 0
    ) {
        self.contractVersion = contractVersion
        self.devices = devices
        self.pcmRouteMode = pcmRouteMode
        self.selectedPCMDeviceID = selectedPCMDeviceID
        self.activeClientID = activeClientID
        self.activeDeviceID = activeDeviceID
        self.activeSampleRate = activeSampleRate
        self.sourceSampleRate = sourceSampleRate
        self.sampleRateMatched = sampleRateMatched
        self.statusDescription = statusDescription
        self.failureMessage = failureMessage
        self.revision = revision
    }
}

public struct AudioDeviceSelectionSnapshot: Codable, Equatable, Sendable {
    public let contractVersion: UInt32
    public var devices: [AudioOutputDeviceDescriptor]
    /// 当前选中的设备 UID；跟随模式下也保留实际设备，供音量和状态呈现使用。
    public var selectedDeviceID: String?
    /// 缺省表示扩展未声明跟随模式；以可用的 selectSystemDefault 动作判断支持情况。
    public var followsSystemDefault: Bool?
    public var outputPolicy: DSDOutputPolicy
    public var activeTransport: AudioOutputTransport?
    public var statusDescription: String?
    public var revision: UInt64

    public init(
        contractVersion: UInt32 = 1,
        devices: [AudioOutputDeviceDescriptor],
        selectedDeviceID: String? = nil,
        followsSystemDefault: Bool? = nil,
        outputPolicy: DSDOutputPolicy = .automatic,
        activeTransport: AudioOutputTransport? = nil,
        statusDescription: String? = nil,
        revision: UInt64 = 0
    ) {
        self.contractVersion = contractVersion
        self.devices = devices
        self.selectedDeviceID = selectedDeviceID
        self.followsSystemDefault = followsSystemDefault
        self.outputPolicy = outputPolicy
        self.activeTransport = activeTransport
        self.statusDescription = statusDescription
        self.revision = revision
    }
}

public enum MediaSessionContractError: LocalizedError, Equatable {
    case unsupportedContractVersion(UInt32)
    case missingCapability(String)
    case duplicateQueueItem(String)
    case invalidCurrentItem(String)
    case invalidPlaybackPosition
    case duplicateDevice(String)
    case invalidSelectedDevice(String)
    case invalidDoPRate(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedContractVersion(let version):
            "Unsupported media contract version: \(version)"
        case .missingCapability(let identifier):
            "Media state is missing an active capability: \(identifier)"
        case .duplicateQueueItem(let identifier):
            "Duplicate playback queue item: \(identifier)"
        case .invalidCurrentItem(let identifier):
            "The current playback item does not exist: \(identifier)"
        case .invalidPlaybackPosition:
            "The playback position is invalid."
        case .duplicateDevice(let identifier):
            "Duplicate audio output device: \(identifier)"
        case .invalidSelectedDevice(let identifier):
            "The selected audio output device is unavailable: \(identifier)"
        case .invalidDoPRate(let identifier):
            "The audio output device has an invalid DoP rate: \(identifier)"
        }
    }
}

public enum MediaSessionContractValidator {
    public static let supportedContractVersion: UInt32 = 1

    public static func validate(_ session: ContentSession) throws {
        if let playback = session.mediaPlayback {
            guard playback.volume.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
                  playback.position.isFinite, playback.position >= 0,
                  playback.duration.map({ $0.isFinite && $0 >= 0 && playback.position <= $0 }) ?? true else {
                throw MediaSessionContractError.invalidPlaybackPosition
            }
            if playback.isSeekable {
                try requireActiveCapability(ExtensionCapabilityIdentifier.seekable, in: session)
            }
        }

        if let queue = session.playbackQueue {
            try requireActiveCapability(ExtensionCapabilityIdentifier.mediaPlaybackQueue, in: session)
            guard queue.contractVersion > 0, queue.contractVersion <= supportedContractVersion else {
                throw MediaSessionContractError.unsupportedContractVersion(queue.contractVersion)
            }
            var identifiers = Set<String>()
            for item in queue.items {
                guard !item.id.isEmpty, !item.title.isEmpty else {
                    throw MediaSessionContractError.duplicateQueueItem(item.id)
                }
                guard identifiers.insert(item.id).inserted else {
                    throw MediaSessionContractError.duplicateQueueItem(item.id)
                }
                guard item.duration.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                    throw MediaSessionContractError.invalidPlaybackPosition
                }
            }
            if let currentItemID = queue.currentItemID, !identifiers.contains(currentItemID) {
                throw MediaSessionContractError.invalidCurrentItem(currentItemID)
            }
        }

        if let selection = session.audioDeviceSelection {
            try requireActiveCapability(ExtensionCapabilityIdentifier.deviceSelector, in: session)
            guard selection.contractVersion > 0,
                  selection.contractVersion <= supportedContractVersion else {
                throw MediaSessionContractError.unsupportedContractVersion(selection.contractVersion)
            }
            var identifiers = Set<String>()
            for device in selection.devices {
                guard !device.id.isEmpty, !device.displayName.isEmpty,
                      identifiers.insert(device.id).inserted else {
                    throw MediaSessionContractError.duplicateDevice(device.id)
                }
                guard device.supportedDoPRates.allSatisfy({ $0 > 0 }),
                      Set(device.supportedDoPRates).count == device.supportedDoPRates.count else {
                    throw MediaSessionContractError.invalidDoPRate(device.id)
                }
            }
            if let selectedDeviceID = selection.selectedDeviceID,
               !selection.devices.contains(where: { $0.id == selectedDeviceID }) {
                throw MediaSessionContractError.invalidSelectedDevice(selectedDeviceID)
            }
        }
    }

    private static func requireActiveCapability(_ identifier: String, in session: ContentSession) throws {
        guard session.extensionID == nil || session.capabilities.contains(where: {
            $0.declaration.id == identifier
                && $0.declaration.contractVersion <= supportedContractVersion
                && $0.state == .active
        }) else {
            throw MediaSessionContractError.missingCapability(identifier)
        }
    }
}

public enum CommandContributionError: LocalizedError, Equatable {
    case missingCapability
    case malformedCommand(String)
    case duplicateCommand(String)
    case missingParent(commandID: String, parentID: String)
    case hierarchyCycle(String)

    public var errorDescription: String? {
        switch self {
        case .missingCapability:
            "Commands require an active command-provider capability."
        case .malformedCommand(let identifier):
            "Invalid extension command: \(identifier)"
        case .duplicateCommand(let identifier):
            "Duplicate extension command: \(identifier)"
        case .missingParent(let commandID, let parentID):
            "Extension command \(commandID) has a missing parent: \(parentID)"
        case .hierarchyCycle(let identifier):
            "Extension command hierarchy contains a cycle at: \(identifier)"
        }
    }
}

public enum CommandContributionValidator {
    public static func validate(_ session: ContentSession) throws {
        guard session.extensionID == nil || session.commands.isEmpty || session.capabilities.contains(where: {
            $0.declaration.id == ExtensionCapabilityIdentifier.commandProvider && $0.state == .active
        }) else {
            throw CommandContributionError.missingCapability
        }

        var commandsByID: [String: CommandDescriptor] = [:]
        for command in session.commands {
            guard !command.id.isEmpty,
                  !command.titleLocalizationKey.isEmpty || command.displayTitle?.isEmpty == false,
                  command.parentID != command.id else {
                throw CommandContributionError.malformedCommand(command.id)
            }
            guard commandsByID.updateValue(command, forKey: command.id) == nil else {
                throw CommandContributionError.duplicateCommand(command.id)
            }
        }
        for command in session.commands {
            if let parentID = command.parentID, commandsByID[parentID] == nil {
                throw CommandContributionError.missingParent(commandID: command.id, parentID: parentID)
            }
            var ancestors = Set<String>()
            var current: CommandDescriptor? = command
            while let candidate = current, let parentID = candidate.parentID {
                guard ancestors.insert(candidate.id).inserted else {
                    throw CommandContributionError.hierarchyCycle(candidate.id)
                }
                current = commandsByID[parentID]
            }
        }
    }
}
