//  ContentSession.swift
//  FoofoilExtensionKit
//
//  Created by tolg on 2026/8/25.

import Foundation

public enum SessionPresentation: Codable, Equatable, Sendable {
    case text(titleKey: String, body: String)
    /// 扩展生成的本地文档。`url` 必须是无远端 host 的绝对文件 URL，可带 fragment 表示章节内锚点；
    /// 文件由扩展持有并随会话生命周期有效，宿主只读加载。
    /// 宿主按用户选择的文档背景色覆盖 html/body 的背景（内联 `!important`）；
    /// 正文容器若另画不透明背景，请改为透明或继承，否则用户设置不会生效。
    /// 文字颜色、字体、行高与段距由宿主写在 html/body 上：颜色/字体是内联属性，
    /// 行距与段距是自定义属性 `--foofoil-document-line-height`、`--foofoil-document-paragraph-spacing`
    /// （外加 `--foofoil-document-font-family`）。正文排版想跟随用户设置时，请在自有 `!important`
    /// 规则里用 `var(--foofoil-document-*, 默认值)`，否则宿主的覆盖到不了元素层。
    case video(VideoPresentationSnapshot)
    case document(url: URL)
    case unavailable(titleKey: String, messageKey: String)

    private enum CodingKeys: String, CodingKey { case kind, titleKey, body, messageKey, url, video }
    private enum Kind: String, Codable { case text, document, video, unavailable }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(
                titleKey: try container.decode(String.self, forKey: .titleKey),
                body: try container.decode(String.self, forKey: .body)
            )
        case .video:
            self = .video(try container.decode(VideoPresentationSnapshot.self, forKey: .video))
        case .document:
            self = .document(url: try container.decode(URL.self, forKey: .url))
        case .unavailable:
            self = .unavailable(
                titleKey: try container.decode(String.self, forKey: .titleKey),
                messageKey: try container.decode(String.self, forKey: .messageKey)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let titleKey, let body):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(titleKey, forKey: .titleKey)
            try container.encode(body, forKey: .body)
        case .video(let frame):
            try container.encode(Kind.video, forKey: .kind)
            try container.encode(frame, forKey: .video)
        case .document(let url):
            try container.encode(Kind.document, forKey: .kind)
            try container.encode(url, forKey: .url)
        case .unavailable(let titleKey, let messageKey):
            try container.encode(Kind.unavailable, forKey: .kind)
            try container.encode(titleKey, forKey: .titleKey)
            try container.encode(messageKey, forKey: .messageKey)
        }
    }
}

public struct CommandDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let titleLocalizationKey: String
    /// 设备名等外部动态值不走本地化；普通宿主 chrome 继续使用 localization key。
    public var displayTitle: String?
    /// 指向同一命令集合中的父命令；宿主据此构造原生子菜单。
    public var parentID: String?
    public var symbolName: String?
    public var keyEquivalent: String?
    public var modifierFlags: UInt
    public var isEnabled: Bool
    public var isChecked: Bool

    public init(
        id: String,
        titleLocalizationKey: String,
        displayTitle: String? = nil,
        parentID: String? = nil,
        symbolName: String? = nil,
        keyEquivalent: String? = nil,
        modifierFlags: UInt = 0,
        isEnabled: Bool = true,
        isChecked: Bool = false
    ) {
        self.id = id
        self.titleLocalizationKey = titleLocalizationKey
        self.displayTitle = displayTitle
        self.parentID = parentID
        self.symbolName = symbolName
        self.keyEquivalent = keyEquivalent
        self.modifierFlags = modifierFlags
        self.isEnabled = isEnabled
        self.isChecked = isChecked
    }
}

public struct NegotiatedCapability: Codable, Equatable, Sendable {
    public let declaration: ExtensionCapabilityDeclaration
    public var state: ExtensionCapabilityState
    public var failureMessage: String?

    public init(
        declaration: ExtensionCapabilityDeclaration,
        state: ExtensionCapabilityState,
        failureMessage: String? = nil
    ) {
        self.declaration = declaration
        self.state = state
        self.failureMessage = failureMessage
    }
}

/// 完整文档的搜索单元；URL 为会话临时、自包含 HTML，定位动作使用既有导航契约。
public struct DocumentSearchSource: Codable, Equatable, Sendable {
    public var url: URL
    public var contributionID: String
    public var itemID: String

    public init(url: URL, contributionID: String, itemID: String) {
        self.url = url
        self.contributionID = contributionID
        self.itemID = itemID
    }
}

public struct ContentSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let extensionID: String?
    public let providerID: String
    public let request: ContentRequest
    public var presentation: SessionPresentation
    public var capabilities: [NegotiatedCapability]
    public var commands: [CommandDescriptor]
    public var navigatorContributions: [NavigatorContribution]
    public var mediaPlayback: MediaPlaybackSnapshot?
    public var playbackQueue: MediaPlaybackQueueSnapshot?
    public var audioDeviceSelection: AudioDeviceSelectionSnapshot?
    /// 会话封面/缩略图的本机文件 URL；宿主可复制其像素用于历史缩略图，不得持久化该 URL 本身。
    /// 文件由扩展持有并随会话生命周期有效；缺省表示无封面。
    public var thumbnailURL: URL?
    public var documentSearchSources: [DocumentSearchSource]?
    public var stateReference: String?

    public init(
        id: UUID = UUID(),
        extensionID: String?,
        providerID: String,
        request: ContentRequest,
        presentation: SessionPresentation,
        capabilities: [NegotiatedCapability] = [],
        commands: [CommandDescriptor] = [],
        navigatorContributions: [NavigatorContribution] = [],
        mediaPlayback: MediaPlaybackSnapshot? = nil,
        playbackQueue: MediaPlaybackQueueSnapshot? = nil,
        audioDeviceSelection: AudioDeviceSelectionSnapshot? = nil,
        thumbnailURL: URL? = nil,
        documentSearchSources: [DocumentSearchSource]? = nil,
        stateReference: String? = nil
    ) {
        self.id = id
        self.extensionID = extensionID
        self.providerID = providerID
        self.request = request
        self.presentation = presentation
        self.capabilities = capabilities
        self.commands = commands
        self.navigatorContributions = navigatorContributions
        self.mediaPlayback = mediaPlayback
        self.playbackQueue = playbackQueue
        self.audioDeviceSelection = audioDeviceSelection
        self.thumbnailURL = thumbnailURL
        self.documentSearchSources = documentSearchSources
        self.stateReference = stateReference
    }

    private enum CodingKeys: String, CodingKey {
        case id, extensionID, providerID, request, presentation, capabilities, commands
        case navigatorContributions, mediaPlayback, playbackQueue, audioDeviceSelection
        case thumbnailURL, stateReference, documentSearchSources
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        extensionID = try container.decodeIfPresent(String.self, forKey: .extensionID)
        providerID = try container.decode(String.self, forKey: .providerID)
        request = try container.decode(ContentRequest.self, forKey: .request)
        presentation = try container.decode(SessionPresentation.self, forKey: .presentation)
        capabilities = try container.decodeIfPresent([NegotiatedCapability].self, forKey: .capabilities) ?? []
        commands = try container.decodeIfPresent([CommandDescriptor].self, forKey: .commands) ?? []
        // Phase 0 早期 Session 没有导航贡献；缺失字段必须保持可恢复。
        navigatorContributions = try container.decodeIfPresent(
            [NavigatorContribution].self,
            forKey: .navigatorContributions
        ) ?? []
        mediaPlayback = try container.decodeIfPresent(MediaPlaybackSnapshot.self, forKey: .mediaPlayback)
        playbackQueue = try container.decodeIfPresent(MediaPlaybackQueueSnapshot.self, forKey: .playbackQueue)
        audioDeviceSelection = try container.decodeIfPresent(
            AudioDeviceSelectionSnapshot.self,
            forKey: .audioDeviceSelection
        )
        thumbnailURL = try container.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        documentSearchSources = try container.decodeIfPresent([DocumentSearchSource].self, forKey: .documentSearchSources)
        stateReference = try container.decodeIfPresent(String.self, forKey: .stateReference)
    }
}

public enum ContentProviderError: LocalizedError, Equatable {
    case unavailable(String)
    case unsupportedRequest
    case sessionCreationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let provider): "Provider unavailable: \(provider)"
        case .unsupportedRequest: "The provider does not support this request."
        case .sessionCreationFailed(let message): message
        }
    }
}
