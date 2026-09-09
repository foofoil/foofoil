//
//  AppKitPopupMenuButton.swift
//  foofoil
//
//  Created by tolg on 2026/9/9.
//

import AppKit
import SwiftUI

/// 用瞬时 NSMenu.popUp 代替 SwiftUI Menu。SwiftUI 的 AppKitPopUpAdaptor 会把宿主箔钉在其他箔上面，并干扰 ⌘H。
struct AppKitPopupMenuButton: NSViewRepresentable {
    struct Item: Identifiable {
        enum Kind {
            case command(title: String, selected: Bool, enabled: Bool, action: () -> Void)
            case separator
        }

        let id: String
        let kind: Kind

        static func command(
            id: String,
            title: String,
            selected: Bool = false,
            enabled: Bool = true,
            action: @escaping () -> Void
        ) -> Item {
            Item(id: id, kind: .command(title: title, selected: selected, enabled: enabled, action: action))
        }

        static func separator(id: String = "separator") -> Item {
            Item(id: id, kind: .separator)
        }
    }

    var title: String
    var symbolName: String
    var items: [Item]
    var tint: NSColor = .white

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.items = items
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        symbol?.isTemplate = true
        button.image = symbol
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: tint,
                .font: NSFont.systemFont(ofSize: 11, weight: .medium)
            ]
        )
        button.contentTintColor = tint
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.invalidateIntrinsicContentSize()
    }

    final class Coordinator: NSObject {
        var items: [Item] = []

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in items {
                switch item.kind {
                case .separator:
                    menu.addItem(.separator())
                case let .command(title, selected, enabled, action):
                    let menuItem = NSMenuItem(
                        title: title,
                        action: #selector(runItem(_:)),
                        keyEquivalent: ""
                    )
                    menuItem.target = self
                    menuItem.representedObject = MenuAction(action)
                    menuItem.state = selected ? .on : .off
                    menuItem.isEnabled = enabled
                    menu.addItem(menuItem)
                }
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
        }

        @objc func runItem(_ sender: NSMenuItem) {
            (sender.representedObject as? MenuAction)?.action()
        }
    }
}

/// NSMenuItem.representedObject 需要类实例才能稳定持有闭包。
private final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) {
        self.action = action
    }
}
