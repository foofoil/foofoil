//  ExtensionModels.swift
//  FoofoilExtensionKit
//
//  Created by tolg on 2026/8/25.

import Foundation

public enum ExtensionAPI {
    public static let v1: UInt32 = 1
    public static let supportedVersions: Set<UInt32> = [v1]

    public static func negotiate(with compatibility: ExtensionAPICompatibility) -> UInt32? {
        supportedVersions
            .filter { compatibility.contains($0) }
            .max()
    }
}

public struct ExtensionAPICompatibility: Codable, Equatable, Sendable {
    public let min: UInt32
    public let max: UInt32

    public init(min: UInt32, max: UInt32) {
        self.min = min
        self.max = max
    }

    public func contains(_ version: UInt32) -> Bool {
        min <= version && version <= max
    }
}

public struct ExtensionSystemRequirements: Codable, Equatable, Sendable {
    public let minMacOS: String
    public let architectures: [String]

    public init(minMacOS: String, architectures: [String]) {
        self.minMacOS = minMacOS
        self.architectures = architectures
    }

    public static var currentArchitecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }

    public func isSatisfied(
        architecture: String = currentArchitecture,
        macOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Bool {
        guard architectures.contains(architecture) else { return false }
        let parts = minMacOS.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return false }
        let required = OperatingSystemVersion(
            majorVersion: parts[0],
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0
        )
        return macOS.majorVersion > required.majorVersion
            || (macOS.majorVersion == required.majorVersion
                && (macOS.minorVersion > required.minorVersion
                    || (macOS.minorVersion == required.minorVersion
                        && macOS.patchVersion >= required.patchVersion)))
    }
}

public enum ExtensionProviderRole: String, Codable, Sendable {
    case primary
    case override
}

/// Provider 内容所属的宿主呈现家族。它只用于把扩展格式归入宿主已有的
/// 列表与交互模型；具体解码器仍由每次打开时的 provider resolution 决定。
public enum ExtensionContentFamily: String, Codable, Sendable {
    case audio
    case video
    case image
}

public enum ContentMatchStrategy: String, Codable, Sendable {
    case fileExtension = "extension"
    case conforms
    case sniff
}

public struct ContentTypeDeclaration: Codable, Equatable, Sendable {
    public var extensions: [String]?
    public var utTypes: [String]?
    public let strategy: ContentMatchStrategy

    public init(extensions: [String]? = nil, utTypes: [String]? = nil, strategy: ContentMatchStrategy) {
        self.extensions = extensions
        self.utTypes = utTypes
        self.strategy = strategy
    }
}

public struct ExtensionProviderDeclaration: Codable, Equatable, Sendable {
    public let id: String
    public let role: ExtensionProviderRole
    public var fallbackProvider: String?
    /// override provider 所属偏好域，例如 audio；旧清单缺失时保持 nil。
    public var enhancementDomain: String?
    /// 复用宿主统一列表/呈现层的内容家族；旧清单缺失时保持 nil。
    public var contentFamily: ExtensionContentFamily?
    public let contentTypes: [ContentTypeDeclaration]

    public init(
        id: String,
        role: ExtensionProviderRole,
        fallbackProvider: String? = nil,
        enhancementDomain: String? = nil,
        contentFamily: ExtensionContentFamily? = nil,
        contentTypes: [ContentTypeDeclaration]
    ) {
        self.id = id
        self.role = role
        self.fallbackProvider = fallbackProvider
        self.enhancementDomain = enhancementDomain
        self.contentFamily = contentFamily
        self.contentTypes = contentTypes
    }
}

public enum ExtensionCapabilityScope: String, Codable, Sendable {
    case application
    case session
    case presentation
}

public enum ExtensionCapabilityState: String, Codable, Sendable {
    case supported
    case available
    case active
    case failed
}

public struct ExtensionCapabilityDeclaration: Codable, Equatable, Sendable {
    public let id: String
    public let contractVersion: UInt32
    public let scope: ExtensionCapabilityScope
    public var dependencies: [String]

    public init(id: String, contractVersion: UInt32 = 1, scope: ExtensionCapabilityScope, dependencies: [String] = []) {
        self.id = id
        self.contractVersion = contractVersion
        self.scope = scope
        self.dependencies = dependencies
    }

    public init(from decoder: Decoder) throws {
        if let id = try? decoder.singleValueContainer().decode(String.self) {
            self.init(id: id, scope: ExtensionCapabilityIdentifier.inferredScope(for: id))
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        self.init(
            id: id,
            contractVersion: try container.decodeIfPresent(UInt32.self, forKey: .contractVersion) ?? 1,
            scope: try container.decodeIfPresent(ExtensionCapabilityScope.self, forKey: .scope)
                ?? ExtensionCapabilityIdentifier.inferredScope(for: id),
            dependencies: try container.decodeIfPresent([String].self, forKey: .dependencies) ?? []
        )
    }
}

public enum ExtensionCapabilityIdentifier {
    public static let mediaTransport = "media.transport"
    public static let navigatorActions = "ui.navigator-actions"
    public static let sessionLifecycle = "session.lifecycle"
    public static let seekable = "session.seekable"
    public static let mediaPlaybackQueue = "media.playback-queue"
    public static let audioEffects = "audio.effects"
    public static let visualization = "audio.visualization"
    public static let subtitle = "video.subtitle"
    public static let controllerInput = "game.controller-input"
    public static let deviceSelector = "audio.device-selection"
    public static let contentProbe = "content.probe"
    public static let settingsProvider = "application.settings"
    public static let commandProvider = "ui.commands"
    public static let navigator = "ui.navigator"
    public static let presentationAdapter = "ui.presentation"

    public static func inferredScope(for identifier: String) -> ExtensionCapabilityScope {
        if identifier.hasPrefix("application.") || identifier == deviceSelector || identifier == contentProbe {
            return .application
        }
        if identifier.hasPrefix("ui.") {
            return .presentation
        }
        return .session
    }
}

public struct ExtensionManifest: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let extensionAPI: ExtensionAPICompatibility
    public let system: ExtensionSystemRequirements
    public let providers: [ExtensionProviderDeclaration]
    public let capabilities: [ExtensionCapabilityDeclaration]

    public init(
        id: String,
        name: String,
        version: String,
        extensionAPI: ExtensionAPICompatibility,
        system: ExtensionSystemRequirements,
        providers: [ExtensionProviderDeclaration],
        capabilities: [ExtensionCapabilityDeclaration]
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.extensionAPI = extensionAPI
        self.system = system
        self.providers = providers
        self.capabilities = capabilities
    }
}

public enum ExtensionManifestError: LocalizedError, Equatable {
    case malformedIdentifier(String)
    case malformedVersion(String)
    case invalidAPIRange
    case incompatibleAPI
    case invalidSystemRequirement
    case duplicateProvider(String)
    case invalidProvider(String)
    case duplicateCapability(String)
    case invalidCapability(String)

    public var errorDescription: String? {
        switch self {
        case .malformedIdentifier(let value): "Invalid extension identifier: \(value)"
        case .malformedVersion(let value): "Invalid semantic version: \(value)"
        case .invalidAPIRange: "The Extension API range is invalid."
        case .incompatibleAPI: "The extension does not support a host Extension API version."
        case .invalidSystemRequirement: "The extension system requirements are invalid."
        case .duplicateProvider(let id): "Duplicate provider identifier: \(id)"
        case .invalidProvider(let id): "Invalid provider declaration: \(id)"
        case .duplicateCapability(let id): "Duplicate capability identifier: \(id)"
        case .invalidCapability(let id): "Invalid capability declaration: \(id)"
        }
    }
}

public enum ExtensionManifestValidator {
    public static func decodeAndValidate(_ data: Data, requireHostCompatibility: Bool = true) throws -> ExtensionManifest {
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(ExtensionManifest.self, from: data)
        try validate(manifest, requireHostCompatibility: requireHostCompatibility)
        return manifest
    }

    public static func validate(_ manifest: ExtensionManifest, requireHostCompatibility: Bool = true) throws {
        let idPattern = #"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*){2,}$"#
        guard manifest.id.range(of: idPattern, options: .regularExpression) != nil else {
            throw ExtensionManifestError.malformedIdentifier(manifest.id)
        }
        let versionPattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#
        guard manifest.version.range(of: versionPattern, options: .regularExpression) != nil else {
            throw ExtensionManifestError.malformedVersion(manifest.version)
        }
        guard manifest.extensionAPI.min > 0,
              manifest.extensionAPI.min <= manifest.extensionAPI.max else {
            throw ExtensionManifestError.invalidAPIRange
        }
        if requireHostCompatibility, ExtensionAPI.negotiate(with: manifest.extensionAPI) == nil {
            throw ExtensionManifestError.incompatibleAPI
        }
        let macOSPattern = #"^[0-9]+(?:\.[0-9]+){0,2}$"#
        let knownArchitectures: Set<String> = ["arm64", "x86_64"]
        guard manifest.system.minMacOS.range(of: macOSPattern, options: .regularExpression) != nil,
              !manifest.system.architectures.isEmpty,
              Set(manifest.system.architectures).count == manifest.system.architectures.count,
              manifest.system.architectures.allSatisfy(knownArchitectures.contains) else {
            throw ExtensionManifestError.invalidSystemRequirement
        }

        var providerIDs = Set<String>()
        for provider in manifest.providers {
            guard providerIDs.insert(provider.id).inserted else {
                throw ExtensionManifestError.duplicateProvider(provider.id)
            }
            let hasValidContentType = provider.contentTypes.allSatisfy { declaration in
                let extensions = declaration.extensions ?? []
                let utTypes = declaration.utTypes ?? []
                guard !(extensions.isEmpty && utTypes.isEmpty) else { return false }
                if declaration.strategy == .sniff {
                    return !extensions.isEmpty || !utTypes.isEmpty
                }
                return extensions.allSatisfy { $0 == $0.lowercased() && !$0.contains(".") }
            }
            guard !provider.id.isEmpty,
                  !provider.contentTypes.isEmpty,
                  hasValidContentType,
                  provider.role != .override || provider.fallbackProvider?.isEmpty == false else {
                throw ExtensionManifestError.invalidProvider(provider.id)
            }
        }

        var capabilityIDs = Set<String>()
        for capability in manifest.capabilities {
            guard capabilityIDs.insert(capability.id).inserted else {
                throw ExtensionManifestError.duplicateCapability(capability.id)
            }
            guard !capability.id.isEmpty,
                  capability.contractVersion > 0,
                  capability.dependencies.allSatisfy({ $0 != capability.id }) else {
                throw ExtensionManifestError.invalidCapability(capability.id)
            }
        }
    }
}
