import Foundation

/// application-scope 内容探测。会话建立前调用，不创建播放会话、不获取设备。
public struct ContentProbeRequest: Codable, Equatable, Sendable {
    public static let commandIdentifier = "content.probe"
    public static let supportedContractVersion: UInt32 = 1
    public static let defaultMaxReadBytes = 2_097_152

    public let commandID: String
    public let contractVersion: UInt32
    public let resource: ExtensionResource
    public var maxReadBytes: Int

    public init(resource: ExtensionResource, maxReadBytes: Int = defaultMaxReadBytes, contractVersion: UInt32 = 1) {
        commandID = Self.commandIdentifier
        self.contractVersion = contractVersion
        self.resource = resource
        self.maxReadBytes = maxReadBytes
    }

    public static func isDeclared(in declarations: [ExtensionCapabilityDeclaration]) -> Bool {
        CapabilityNegotiator.negotiate(declarations).accepted.contains {
            $0.declaration.id == ExtensionCapabilityIdentifier.contentProbe
        }
    }

    public func validate() throws {
        guard commandID == Self.commandIdentifier, contractVersion == 1 else {
            throw ContentProbeError.unsupportedContract
        }
        guard maxReadBytes > 0 else { throw ContentProbeError.invalidBudget }
    }
}

public enum ContentProbeDisposition: String, Codable, Equatable, Sendable {
    case unmatched
    case matched
}

public struct ContentProbeResult: Codable, Equatable, Sendable {
    public let contractVersion: UInt32
    public let disposition: ContentProbeDisposition
    public var reason: String?
    public var itemCount: Int?
    public var title: String?

    public init(
        contractVersion: UInt32 = 1,
        disposition: ContentProbeDisposition,
        reason: String? = nil,
        itemCount: Int? = nil,
        title: String? = nil
    ) {
        self.contractVersion = contractVersion
        self.disposition = disposition
        self.reason = reason
        self.itemCount = itemCount
        self.title = title
    }
}

public enum ContentProbeError: Error, Equatable {
    case unsupportedContract
    case missingCapability
    case invalidBudget
}
