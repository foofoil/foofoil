//  ContentProvider.swift
//  foofoil
//
//  Created by tolg on 2026/8/25.

import FoofoilExtensionKit
import Foundation

/// 仅供 Host 内部和经过验证的进程内样机使用；跨 Release 的边界是 C ABI 或 XPC Data 消息。
protocol ContentProvider: AnyObject {
    var descriptor: ProviderDescriptor { get }
    func match(_ request: ContentRequest) -> ProviderMatch?
    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession
    func perform(commandID: String, session: ContentSession) async throws -> ContentSession
    func perform(mediaAction: MediaPlaybackAction, session: ContentSession) async throws -> ContentSession
    func perform(navigatorAction: NavigatorAction, session: ContentSession) async throws -> ContentSession
    func restorePlayback(from saved: ContentSession, in fresh: ContentSession) async throws -> ContentSession
    func closeSession(_ session: ContentSession) async throws
}

extension ContentProvider {
    func perform(mediaAction: MediaPlaybackAction, session: ContentSession) async throws -> ContentSession {
        try await HiFiLegacyAdapter.perform(mediaAction: mediaAction, session: session, provider: self)
    }
    func perform(commandID: String, session: ContentSession) async throws -> ContentSession {
        session
    }

    func perform(navigatorAction: NavigatorAction, session: ContentSession) async throws -> ContentSession {
        session
    }

    /// 默认只保留新会话；扩展私有恢复状态由具体 Provider 解释。
    func restorePlayback(from saved: ContentSession, in fresh: ContentSession) async throws -> ContentSession {
        fresh
    }

    /// 无外部资源的 Provider 无需关闭；持有资源的实现必须等待释放完成。
    func closeSession(_ session: ContentSession) async throws {}

    func performValidated(commandID: String, session: ContentSession) async throws -> ContentSession {
        try Self.validateSession(await perform(commandID: commandID, session: session))
    }

    func performValidated(navigatorAction: NavigatorAction, session: ContentSession) async throws -> ContentSession {
        guard let contribution = session.navigatorContributions.first(where: {
            $0.id == navigatorAction.contributionID
        }) else {
            throw NavigatorContributionError.invalidAction(navigatorAction.contributionID)
        }
        try NavigatorContributionValidator.validate(navigatorAction, in: contribution)
        return try Self.validateSession(await perform(navigatorAction: navigatorAction, session: session))
    }

    /// 恢复中的中间结果与普通交互使用相同校验，避免后续命令消费无效快照。
    static func validateSession(_ session: ContentSession) throws -> ContentSession {
        try NavigatorContributionValidator.validate(session)
        try CommandContributionValidator.validate(session)
        try MediaSessionContractValidator.validate(session)
        return session
    }
}
