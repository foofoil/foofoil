//  AppState+ColorPanel.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//


import Foundation
import Combine
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO
import SwiftUI


extension AppState {
        // MARK: - NSColorPanel Support

        public func showColorPanel() {
            let panel = NSColorPanel.shared
            // 面板是应用级单例：先摘掉上一扇箔的回包，避免下面同步色板颜色时把颜色写回旧窗口。
            (NSApplication.shared.delegate as? AppDelegate)?.colorPanelOwner = self
            panel.setAction(nil)
            panel.showsAlpha = true
            if let hex = svgColor, let nsColor = NSColor(hex: hex) {
                panel.color = nsColor
            }
            panel.setTarget(self)
            panel.setAction(#selector(colorPanelChanged(_:)))

            // 创建一个重置按钮的 accessoryView，当点击时重置为原色
            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
            let button = NSButton(title: NSLocalizedString("Reset Color", comment: ""), target: self, action: #selector(resetColorFromPanel))
            button.frame = NSRect(x: 10, y: 4, width: 180, height: 24)
            button.bezelStyle = .rounded
            accessory.addSubview(button)
            panel.accessoryView = accessory

            panel.makeKeyAndOrderFront(nil)
        }

        /// 取色面板是应用级单例：只有它仍属于本箔、且本箔窗口仍打开时才接受取色，
        /// 面板被其他窗口接管或本箔已关闭后，取色不再落到任何窗口。
        /// 文档样式面板用自己的窗口，不经这里。
        private var ownsColorPanel: Bool {
            guard let appDelegate = NSApplication.shared.delegate as? AppDelegate,
                  appDelegate.colorPanelOwner === self else { return false }
            return appDelegate.windowControllers.contains { $0.appState === self }
        }

        @objc func colorPanelChanged(_ sender: NSColorPanel) {
            guard sender.isVisible, ownsColorPanel else { return }

            if let hex = sender.color.toHex() {
                self.svgColor = hex
            }
        }

        @objc func resetColorFromPanel() {
            guard ownsColorPanel else { return }
            self.svgColor = nil
            // 同步把调色盘重设为某个默认值，防止用户误以为没生效，不过其实重置为原色后，调色盘里的颜色本身没有硬性规定
        }
}
