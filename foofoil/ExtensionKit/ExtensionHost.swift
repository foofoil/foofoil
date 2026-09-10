//  ExtensionHost.swift
//  foofoil
//
//  Created by tolg on 2026/8/25.

import Foundation
import FoofoilExtensionKit
import UniformTypeIdentifiers

final class ExtensionHost: ExtensionRuntimeHost {
    static let shared = ExtensionHost()

    let resolver: ProviderResolver
    let stateStore: ExtensionStateStore
    let manager: ExtensionManager
    private var audioEnhancer: AudioEnhancerTestProvider?
    private var preferredProvidersByDomain: [String: String]
    private var sessionCounts: [String: Int] = [:]
    private var loadedInProcess: Set<String> = []
    private var inProcessRuntimes: [String: InProcessExtensionInterface] = [:]
    private var inProcessManifests: [String: ExtensionManifest] = [:]
    private let sessionLock = NSLock()

    init(
        resolver: ProviderResolver = ProviderResolver(),
        stateStore: ExtensionStateStore = ExtensionStateStore(),
        manager: ExtensionManager? = nil
    ) {
        self.resolver = resolver
        self.stateStore = stateStore
        self.preferredProvidersByDomain = SettingsStore.shared.preferredProvidersByDomain
        resolver.register(BuiltInAudioProvider())
        let resolvedManager = manager ?? ExtensionManager()
        self.manager = resolvedManager
        resolvedManager.host = self
        resolvedManager.loadInstalledRuntimes()
#if DEBUG
        loadBundledDevelopmentRuntimes()
#endif
    }

    func setPreferredProvider(_ providerID: String?, for domain: String) {
        preferredProvidersByDomain[domain] = providerID
        SettingsStore.shared.preferredProvidersByDomain = preferredProvidersByDomain
    }

    func preferredProvider(for domain: String) -> String? {
        preferredProvidersByDomain[domain]
    }

    private var audioDeviceService: (any ExtensionAudioDeviceServicing)? {
        let capableIDs = inProcessManifests.compactMap { id, manifest in
            AudioDeviceServiceRequest.isDeclared(in: manifest.capabilities) ? id : nil
        }
        let preferredProviderID = preferredProvidersByDomain["audio"]
        let preferredExtensionID = preferredProviderID.flatMap { resolver.provider(id: $0)?.descriptor.extensionID }
        if let extensionID = ExtensionAudioDeviceDiscovery.extensionID(
            amongCapable: capableIDs, preferredExtensionID: preferredExtensionID
        ), let runtime = inProcessRuntimes[extensionID] {
            return HiFiLegacyAudioDeviceService { request in
                try runtime.performApplicationCommand(request)
            }
        }
        return HiFiLegacyAdapter.audioDeviceService(in: inProcessRuntimes)
    }

    var isAudioDeviceServiceAvailable: Bool { audioDeviceService != nil }

    func performAudioDeviceCommand(
        _ request: AudioDeviceServiceRequest
    ) async throws -> AudioDeviceServiceSnapshot {
        guard let service = audioDeviceService else {
            throw ContentProviderError.unsupportedRequest
        }
        return try await service.perform(request)
    }

    func shutdownAndWait() async {
        let runtimes = Array(inProcessRuntimes.values)
        await Task.detached(priority: .userInitiated) {
            for runtime in runtimes { runtime.shutdown() }
        }.value
    }

    func canOpen(url: URL) -> Bool {
        let request = ContentRequest.singleFile(.init(url: url))
        let candidates = resolver.candidates(for: request)
        let domain = candidates.compactMap(\.descriptor.enhancementDomain).first
        let preferred = domain.flatMap { preferredProvidersByDomain[$0] }
        guard let resolution = try? resolver.resolve(request, preferredProviderID: preferred),
              let provider = resolver.provider(id: resolution.selectedProviderID) else { return false }
        return !provider.descriptor.isBuiltIn
    }

    /// 正式安装与 `./run` 注入的开发 Runtime 都属于可用扩展；后者不会写安装记录。
    func isExtensionAvailable(_ extensionID: String) -> Bool {
        manager.isInstalledAndEnabled(extensionID)
            || resolver.allDescriptors().contains {
                $0.extensionID == extensionID && $0.isEnabled && $0.isRuntimeAvailable
            }
    }

    /// 扩展只声明内容家族，宿主据此决定应复用哪一套列表与呈现；
    /// 是否真的由该扩展播放，仍在打开当前项目时重新执行 provider resolution。
    func canOpenAsAudio(url: URL) -> Bool {
        let request = ContentRequest.singleFile(.init(url: url))
        return resolver.candidates(for: request).contains {
            !$0.descriptor.isBuiltIn && $0.descriptor.contentFamily == .audio
        }
    }

    func additionalContentTypes(for family: ExtensionContentFamily) -> [UTType] {
        let extensions = resolver.allDescriptors()
            .filter { !$0.isBuiltIn && $0.contentFamily == family }
            .flatMap(\.filenameExtensions)
        var seen = Set<String>()
        return extensions.compactMap { UTType(filenameExtension: $0) }.filter {
            seen.insert($0.identifier).inserted
        }
    }

    func open(url: URL) async throws -> SessionResolutionOutcome {
        try await open(request: .singleFile(.sandboxed(url: url)))
    }

    /// 用已持久化的资源与安全范围书签重建运行时会话，而不是复用已经关闭的 Session UUID。
    func open(request: ContentRequest) async throws -> SessionResolutionOutcome {
        let domain = resolver.candidates(for: request).compactMap(\.descriptor.enhancementDomain).first
        return try await resolver.makeSession(
            for: request,
            preferredProviderID: domain.flatMap { preferredProvidersByDomain[$0] }
        )
    }

    func open(urls: [URL]) async throws -> SessionResolutionOutcome {
        let request = ContentRequest.fileCollection(urls.map(ExtensionResource.sandboxed(url:)))
        let domain = resolver.candidates(for: request).compactMap(\.descriptor.enhancementDomain).first
        return try await resolver.makeSession(
            for: request,
            preferredProviderID: domain.flatMap { preferredProvidersByDomain[$0] }
        )
    }

    func perform(commandID: String, in session: ContentSession) async throws -> ContentSession {
        guard let provider = resolver.provider(id: session.providerID) else {
            throw ContentProviderError.unavailable(session.providerID)
        }
        return try await provider.performValidated(commandID: commandID, session: session)
    }

    func perform(mediaAction: MediaPlaybackAction, in session: ContentSession) async throws -> ContentSession {
        try mediaAction.validate()
        guard let provider = resolver.provider(id: session.providerID) else {
            throw ContentProviderError.unavailable(session.providerID)
        }
        let updated = try await provider.perform(mediaAction: mediaAction, session: session)
        return try type(of: provider).validateSession(updated)
    }

    /// 通知 Provider 释放会话资源；具体实现决定是否需要向扩展发送关闭消息。
    func closeSession(_ session: ContentSession) {
        Task { @MainActor in
            await closeSessionAndWait(session)
        }
    }

    /// 需要紧接着接管同一硬件资源时使用。等待 Provider 关闭完成；失败记录日志。
    func closeSessionAndWait(_ session: ContentSession) async {
        guard let provider = resolver.provider(id: session.providerID) else { return }
        do {
            try await provider.closeSession(session)
        } catch {
            NSLog("Extension session close failed: \(error.localizedDescription)")
        }
    }

    func perform(navigatorAction: NavigatorAction, in session: ContentSession) async throws -> ContentSession {
        guard let provider = resolver.provider(id: session.providerID) else {
            throw ContentProviderError.unavailable(session.providerID)
        }
        return try await provider.performValidated(navigatorAction: navigatorAction, session: session)
    }

    /// 宿主只路由恢复请求；各 Provider 解释自己的状态，切换 Provider 时不重放旧状态。
    func restorePlayback(from saved: ContentSession, in fresh: ContentSession) async throws -> ContentSession {
        guard saved.providerID == fresh.providerID else { return fresh }
        guard let provider = resolver.provider(id: fresh.providerID) else {
            throw ContentProviderError.unavailable(fresh.providerID)
        }
        let restored = try await provider.restorePlayback(from: saved, in: fresh)
        return try type(of: provider).validateSession(restored)
    }

    func setTestAudioEnhancerFailure(_ shouldFail: Bool) {
        audioEnhancer?.failSessionCreation = shouldFail
    }

    func retainSession(extensionID: String) {
        sessionLock.lock()
        sessionCounts[extensionID, default: 0] += 1
        sessionLock.unlock()
    }

    func releaseSession(extensionID: String) {
        sessionLock.lock()
        let next = max(0, (sessionCounts[extensionID] ?? 0) - 1)
        if next == 0 {
            sessionCounts.removeValue(forKey: extensionID)
        } else {
            sessionCounts[extensionID] = next
        }
        sessionLock.unlock()
        try? manager.completePendingRemovals()
    }

    func activateRuntime(for loaded: LoadedExtension) {
        if loaded.manifest.id == LocalTestExtension.identifier {
            resolver.unregisterProviders(extensionID: loaded.manifest.id)
            audioEnhancer = LocalTestExtension.register(in: resolver)
        } else if loaded.executionModel == .inProcess {
            do {
                let runtime = try manager.makeLoader().openInProcessInterface(loaded)
                resolver.unregisterProviders(extensionID: loaded.manifest.id)
                for declaration in loaded.manifest.providers {
                    resolver.register(InProcessContentProvider(
                        extensionID: loaded.manifest.id,
                        declaration: declaration,
                        runtime: runtime,
                        capabilities: loaded.manifest.capabilities
                    ))
                }
                inProcessRuntimes[loaded.manifest.id] = runtime
                inProcessManifests[loaded.manifest.id] = loaded.manifest
            } catch {
                NSLog("Extension runtime activation failed: \(error.localizedDescription)")
                return
            }
        }
        markLoadedInProcess(loaded.manifest.id)
    }

    func deactivateRuntime(extensionID: String) {
        resolver.unregisterProviders(extensionID: extensionID)
        inProcessRuntimes.removeValue(forKey: extensionID)
        inProcessManifests.removeValue(forKey: extensionID)
        if extensionID == LocalTestExtension.identifier {
            audioEnhancer = nil
        }
    }

    func hasActiveSessions(for extensionID: String) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return (sessionCounts[extensionID] ?? 0) > 0
    }

    func isLoadedInProcess(_ extensionID: String) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return loadedInProcess.contains(extensionID)
    }

    func markLoadedInProcess(_ extensionID: String) {
        sessionLock.lock()
        loadedInProcess.insert(extensionID)
        sessionLock.unlock()
    }

#if DEBUG
    /// `./run` 注入的开发插件不写安装状态；Release 只从正式安装目录加载。
    private func loadBundledDevelopmentRuntimes() {
        guard let directory = Bundle.main.builtInPlugInsURL else { return }
        let loader = manager.makeLoader()
        for discovered in loader.discover(in: directory) {
            guard case .success(let loaded) = discovered.result else {
                if case .failure(let error) = discovered.result {
                    NSLog("Development extension load failed: \(error.localizedDescription)")
                }
                continue
            }
            activateRuntime(for: loaded)
        }
    }
#endif
}
