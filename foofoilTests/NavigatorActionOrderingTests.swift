//  NavigatorActionOrderingTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/9/13.
//

import Foundation
import FoofoilExtensionKit
import Testing
@testable import foofoil

extension ExtensionKitTests {
    @MainActor
    @Suite
    struct NavigatorActionOrderingTests {
        @Test func consecutiveActionsRunInClickOrder() async throws {
            let provider = NavigatorOrderingTestProvider()
            let host = ExtensionHost.shared
            host.resolver.register(provider)
            defer { host.resolver.unregister(providerID: provider.descriptor.id) }
            let session = try await provider.makeSession(
                for: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/order.ebk"))), negotiatedAPI: 1
            )
            let state = AppState()
            defer { state.extensionSession = nil }
            state.extensionSession = session

            // 第二项故意变慢：没有串行队列时慢项会晚于后点击的第三项完成。
            provider.delayForItemID = "item-b"
            state.performNavigatorAction(action(itemID: "item-b"))
            state.performNavigatorAction(action(itemID: "item-a"))
            state.performNavigatorAction(action(itemID: "item-c"))
            await waitForIdle(state)

            #expect(provider.actions == ["activate:item-b", "activate:item-a", "activate:item-c"])
            #expect(state.extensionSession?.navigatorContributions.first?.selectedItemIDs == ["item-c"])
        }

        @Test func activateMoveAndRemoveQueueInOrder() async throws {
            let provider = NavigatorOrderingTestProvider()
            let host = ExtensionHost.shared
            host.resolver.register(provider)
            defer { host.resolver.unregister(providerID: provider.descriptor.id) }
            let session = try await provider.makeSession(
                for: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/order.ebk"))), negotiatedAPI: 1
            )
            let state = AppState()
            defer { state.extensionSession = nil }
            state.extensionSession = session

            state.performNavigatorAction(action(itemID: "item-b"))
            state.performNavigatorAction(NavigatorAction(
                contributionID: "test.queue",
                kind: .move,
                itemIDs: ["item-c"],
                destinationItemID: "item-a",
                movePosition: .before
            ))
            state.performNavigatorAction(NavigatorAction(
                contributionID: "test.queue",
                kind: .remove,
                itemIDs: ["item-a"]
            ))
            await waitForIdle(state)

            #expect(provider.actions == ["activate:item-b", "move:item-c", "remove:item-a"])
            let queue = try #require(state.extensionSession?.navigatorContributions.first)
            #expect(queue.items.map(\.id) == ["item-c", "item-b"])
        }

        @Test func sessionReplacementDiscardsInFlightAndQueuedActions() async throws {
            let provider = NavigatorOrderingTestProvider()
            let host = ExtensionHost.shared
            host.resolver.register(provider)
            defer { host.resolver.unregister(providerID: provider.descriptor.id) }
            let sessionA = try await provider.makeSession(
                for: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/order.ebk"))), negotiatedAPI: 1
            )
            let sessionB = try await provider.makeSession(
                for: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/order.ebk"))), negotiatedAPI: 1
            )
            #expect(sessionA.id != sessionB.id)

            let state = AppState()
            defer { state.extensionSession = nil }
            state.extensionSession = sessionA
            provider.delayForItemID = "item-a"
            state.performNavigatorAction(action(itemID: "item-a"))
            for _ in 0..<100 where provider.actions.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            state.performNavigatorAction(action(itemID: "item-b")) // 旧会话排队后应立即被丢弃

            state.extensionSession = sessionB
            state.performNavigatorAction(action(itemID: "item-b"))
            await waitForIdle(state)

            #expect(provider.actions == ["activate:item-a", "activate:item-b"])
            #expect(state.extensionSession?.id == sessionB.id)
            #expect(state.extensionSession?.navigatorContributions.first?.selectedItemIDs == ["item-b"])
        }

        private func action(itemID: String) -> NavigatorAction {
            NavigatorAction(contributionID: "test.queue", kind: .activate, itemIDs: [itemID])
        }

        private func waitForIdle(_ state: AppState) async {
            for _ in 0..<300 where state.isNavigatorActionInFlight || !state.pendingNavigatorActions.isEmpty {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}

private final class NavigatorOrderingTestProvider: ContentProvider {
    let descriptor = ProviderDescriptor(
        id: "test.navigator-order",
        extensionID: "app.foofoil.extension.test-navigator-order",
        role: .primary,
        fallbackProviderID: nil,
        enhancementDomain: nil,
        contentFamily: nil,
        filenameExtensions: ["ebk"],
        isEnabled: true,
        isRuntimeAvailable: true
    )
    private(set) var actions: [String] = []
    var delayForItemID: String?

    func match(_ request: ContentRequest) -> ProviderMatch? {
        request.primaryFileURL?.pathExtension.lowercased() == "ebk"
            ? ProviderMatch(strength: .fileExtension, explanation: "navigator-order")
            : nil
    }

    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession {
        ContentSession(
            extensionID: descriptor.extensionID,
            providerID: descriptor.id,
            request: request,
            presentation: .text(titleKey: "Ordering", body: request.primaryFileURL?.lastPathComponent ?? ""),
            capabilities: [
                .init(
                    declaration: .init(id: ExtensionCapabilityIdentifier.navigator, scope: .presentation),
                    state: .active
                ),
                .init(
                    declaration: .init(id: ExtensionCapabilityIdentifier.navigatorActions, scope: .presentation),
                    state: .active
                )
            ],
            navigatorContributions: [
                .init(
                    id: "test.queue",
                    titleLocalizationKey: "Queue",
                    style: .flat,
                    items: [
                        .init(id: "item-a", title: "A", isCurrent: true),
                        .init(id: "item-b", title: "B"),
                        .init(id: "item-c", title: "C")
                    ],
                    selectedItemIDs: ["item-a"],
                    allowedActions: [.activate, .move, .remove]
                )
            ]
        )
    }

    func perform(navigatorAction: NavigatorAction, session: ContentSession) async throws -> ContentSession {
        var updated = session
        guard let index = updated.navigatorContributions.firstIndex(where: {
            $0.id == navigatorAction.contributionID
        }) else { return session }
        switch navigatorAction.kind {
        case .activate:
            let itemID = navigatorAction.itemIDs[0]
            actions.append("activate:\(itemID)")
            if itemID == delayForItemID {
                try await Task.sleep(for: .milliseconds(80))
            }
            updated.navigatorContributions[index].selectedItemIDs = [itemID]
            updated.navigatorContributions[index].items = updated.navigatorContributions[index].items.map {
                var item = $0
                item.isCurrent = item.id == itemID
                return item
            }
        case .move:
            actions.append("move:\(navigatorAction.itemIDs.joined(separator: ","))")
            guard let destination = navigatorAction.destinationItemID else { return session }
            var items = updated.navigatorContributions[index].items
            let moving = items.filter { navigatorAction.itemIDs.contains($0.id) }
            items.removeAll { navigatorAction.itemIDs.contains($0.id) }
            if let target = items.firstIndex(where: { $0.id == destination }) {
                let insertion = navigatorAction.movePosition == .after ? target + 1 : target
                items.insert(contentsOf: moving, at: insertion)
            }
            updated.navigatorContributions[index].items = items
        case .remove:
            actions.append("remove:\(navigatorAction.itemIDs.joined(separator: ","))")
            updated.navigatorContributions[index].items.removeAll {
                navigatorAction.itemIDs.contains($0.id)
            }
            updated.navigatorContributions[index].selectedItemIDs.removeAll {
                navigatorAction.itemIDs.contains($0)
            }
        }
        updated.navigatorContributions[index].revision += 1
        return updated
    }
}
