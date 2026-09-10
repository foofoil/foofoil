//  InProcessContentProvider.swift
//  foofoil
//
//  Created by tolg on 2026/8/25.

import Foundation
import FoofoilExtensionKit

/// 把稳定 C ABI 的 JSON 值消息适配为宿主内部 Provider；插件对象不会跨越 ABI 边界。
final class InProcessContentProvider: ContentProvider {
    let descriptor: ProviderDescriptor

    private let declaration: ExtensionProviderDeclaration
    private let runtime: InProcessExtensionInterface
    private let capabilities: [ExtensionCapabilityDeclaration]

    init(
        extensionID: String,
        declaration: ExtensionProviderDeclaration,
        runtime: InProcessExtensionInterface,
        capabilities: [ExtensionCapabilityDeclaration] = []
    ) {
        self.declaration = declaration
        self.runtime = runtime
        self.capabilities = capabilities
        descriptor = ProviderDescriptor(
            id: declaration.id,
            extensionID: extensionID,
            role: declaration.role,
            fallbackProviderID: declaration.fallbackProvider,
            enhancementDomain: declaration.enhancementDomain,
            contentFamily: declaration.contentFamily,
            filenameExtensions: declaration.contentTypes.flatMap { $0.extensions ?? [] },
            isEnabled: true,
            isRuntimeAvailable: true
        )
    }

    func match(_ request: ContentRequest) -> ProviderMatch? {
        ProviderContentMatcher.match(
            request,
            declarations: declaration.contentTypes,
            sniff: sniffContent
        )
    }

    /// 已声明 `content.probe` 时把嗅探交给扩展；旧 Hi-Fi 无该能力时仍读主 TOC 魔数。
    private func sniffContent(_ url: URL) -> Bool {
        ExtensionContentMatching.sniff(
            url,
            providerID: declaration.id,
            capabilities: capabilities,
            probe: probeContent
        )
    }

    private func probeContent(_ url: URL) -> ContentProbeResult? {
        do {
            let request = ContentProbeRequest(resource: ExtensionResource(url: url))
            try request.validate()
            return try runtime.performApplicationCommand(request, as: ContentProbeResult.self)
        } catch {
            return nil
        }
    }

    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession {
        let runtime = runtime
        return try await Task.detached(priority: .userInitiated) {
            try runtime.createSession(for: request)
        }.value
    }

    func perform(commandID: String, session: ContentSession) async throws -> ContentSession {
        let runtime = runtime
        return try await Task.detached(priority: .userInitiated) {
            try runtime.perform(commandID: commandID, session: session)
        }.value
    }

    func perform(mediaAction: MediaPlaybackAction, session: ContentSession) async throws -> ContentSession {
        guard MediaPlaybackRequest.isSupported(by: session) else {
            return try await HiFiLegacyAdapter.perform(mediaAction: mediaAction, session: session, provider: self)
        }
        let runtime = runtime
        let request = MediaPlaybackRequest(action: mediaAction, session: session)
        return try await Task.detached(priority: .userInitiated) {
            try runtime.perform(media: request)
        }.value
    }

    func restorePlayback(from saved: ContentSession, in fresh: ContentSession) async throws -> ContentSession {
        if let request = ExtensionSessionLifecycle.restorationRequest(from: saved, in: fresh) {
            return try await performLifecycle(request)
        }
        return try await HiFiLegacyAdapter.restorePlayback(saved: saved, fresh: fresh, provider: self)
    }

    func closeSession(_ session: ContentSession) async throws {
        if SessionLifecycleRequest.isSupported(by: session) {
            _ = try await performLifecycle(.init(operation: .close, session: session))
            return
        }
        try await HiFiLegacyAdapter.closeSession(session, provider: self)
    }

    private func performLifecycle(_ request: SessionLifecycleRequest) async throws -> ContentSession {
        let runtime = runtime
        return try await Task.detached(priority: .userInitiated) {
            try runtime.perform(lifecycle: request)
        }.value
    }

    func perform(navigatorAction: NavigatorAction, session: ContentSession) async throws -> ContentSession {
        if NavigatorActionRequest.isSupported(by: session) {
            let runtime = runtime
            let request = NavigatorActionRequest(action: navigatorAction, session: session)
            return try await Task.detached(priority: .userInitiated) {
                try runtime.perform(navigation: request)
            }.value
        }
        guard let request = HiFiLegacyAdapter.navigatorRequest(action: navigatorAction, session: session) else {
            return session
        }
        let commandID = request.commandID
        let requested = request.session
        let runtime = runtime
        return try await Task.detached(priority: .userInitiated) {
            try runtime.perform(commandID: commandID, session: requested)
        }.value
    }
}

enum ExtensionContentMatching {
    static func sniff(
        _ url: URL,
        providerID: String,
        capabilities: [ExtensionCapabilityDeclaration],
        probe: ((URL) -> ContentProbeResult?)? = nil
    ) -> Bool {
        if ContentProbeRequest.isDeclared(in: capabilities) {
            return probe?(url)?.disposition == .matched
        }
        return HiFiLegacyAdapter.matchesLegacyContent(url, providerID: providerID)
    }
}
