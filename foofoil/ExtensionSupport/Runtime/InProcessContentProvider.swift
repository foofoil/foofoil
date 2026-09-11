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

    /// 只支持公共 `content.probe`；不再回退到旧 Hi-Fi SACD 魔数嗅探。
    private func sniffContent(_ url: URL) -> Bool {
        ExtensionContentMatching.sniff(
            url,
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
            throw ContentProviderError.unsupportedRequest
        }
        let runtime = runtime
        let request = MediaPlaybackRequest(action: mediaAction, session: session)
        return try await Task.detached(priority: .userInitiated) {
            try runtime.perform(media: request)
        }.value
    }

    func restorePlayback(from saved: ContentSession, in fresh: ContentSession) async throws -> ContentSession {
        guard let request = ExtensionSessionLifecycle.restorationRequest(from: saved, in: fresh) else {
            return fresh
        }
        return try await performLifecycle(request)
    }

    func closeSession(_ session: ContentSession) async throws {
        guard SessionLifecycleRequest.isSupported(by: session) else { return }
        _ = try await performLifecycle(.init(operation: .close, session: session))
    }

    private func performLifecycle(_ request: SessionLifecycleRequest) async throws -> ContentSession {
        let runtime = runtime
        return try await Task.detached(priority: .userInitiated) {
            try runtime.perform(lifecycle: request)
        }.value
    }

    func perform(navigatorAction: NavigatorAction, session: ContentSession) async throws -> ContentSession {
        guard NavigatorActionRequest.isSupported(by: session) else {
            // 未协商 `ui.navigator-actions`：明确保持会话，不构造任何私有导航命令。
            return session
        }
        let runtime = runtime
        let request = NavigatorActionRequest(action: navigatorAction, session: session)
        return try await Task.detached(priority: .userInitiated) {
            try runtime.perform(navigation: request)
        }.value
    }
}

enum ExtensionContentMatching {
    static func sniff(
        _ url: URL,
        capabilities: [ExtensionCapabilityDeclaration],
        probe: ((URL) -> ContentProbeResult?)? = nil
    ) -> Bool {
        guard ContentProbeRequest.isDeclared(in: capabilities) else { return false }
        return probe?(url)?.disposition == .matched
    }
}
