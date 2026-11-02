//  NSMenuItem+Symbol.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//

import AppKit

extension NSMenuItem {
    /// 使用系统符号统一菜单图标，同时保留 AppKit 对禁用状态的自动着色。
    @discardableResult
    func withSymbol(_ symbolName: String) -> Self {
        withImage(NSImage.historySymbol(named: symbolName))
    }

    @discardableResult
    func withImage(_ menuImage: NSImage?) -> Self {
        image = menuImage
        if #available(macOS 27.0, *) {
            preferredImageVisibility = .visible
        }
        return self
    }
}

extension NSImage {
    /// 文件夹外框与媒体符号组合为模板图标，沿用菜单和卡片的前景色。
    static func historySymbol(named name: String) -> NSImage? {
        let prefix = "foofoil.folder."
        guard name.hasPrefix(prefix), let mode = CollectionSidebarMode(rawValue: String(name.dropFirst(prefix.count))),
              mode != .folder else { return NSImage(systemSymbolName: name, accessibilityDescription: nil) }
        guard let folder = NSImage(systemSymbolName: "questionmark.folder", accessibilityDescription: nil),
              let media = NSImage(systemSymbolName: mode == .video ? "play.fill" : (mode == .audio ? "music.note" : "photo"), accessibilityDescription: nil) else { return nil }
        let folderHeight = 60 * folder.size.height / folder.size.width
        let folderRect = NSRect(x: 2, y: (64 - folderHeight) / 2, width: 60, height: folderHeight)
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { _ in
            // 保留 questionmark.folder 外框，裁去中央问号再绘制媒体符号。
            NSGraphicsContext.saveGraphicsState()
            let outline = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 64, height: 64))
            outline.appendRect(NSRect(x: 21, y: 18.3, width: 22, height: 25.8))
            outline.windingRule = .evenOdd
            outline.addClip()
            folder.draw(in: folderRect)
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 64, height: 18.3)).addClip()
            folder.draw(in: folderRect)
            NSGraphicsContext.restoreGraphicsState()
            if mode == .image {
                // 图片类型只保留山与太阳，放大至文件夹内容区域。
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 22, y: 35, width: 5, height: 5)).fill()
                let mountains = NSBezierPath()
                mountains.move(to: NSPoint(x: 19, y: 21))
                mountains.line(to: NSPoint(x: 28, y: 33))
                mountains.line(to: NSPoint(x: 32, y: 28))
                mountains.line(to: NSPoint(x: 36, y: 33))
                mountains.line(to: NSPoint(x: 45, y: 21))
                mountains.close()
                mountains.fill()
            } else {
                media.draw(in: NSRect(x: 21, y: 20, width: 22, height: 22))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

extension NSMenu {
    /// macOS 27 默认隐藏菜单图标；也处理 SwiftUI 动态生成的右键菜单及子菜单。
    func restoreItemImageVisibility() {
        guard #available(macOS 27.0, *) else { return }
        for index in items.indices { restoreItemImageVisibility(at: index) }
    }

    /// SwiftUI 可以在开始跟踪后才插入菜单项或补上 image；仅修正变动项，避免每次更新遍历整棵菜单。
    func restoreItemImageVisibility(at index: Int) {
        guard #available(macOS 27.0, *), items.indices.contains(index) else { return }
        let item = items[index]
        // 修改可见性也可能触发菜单更新；已修正的条目不重复赋值，避免通知重入。
        if item.image != nil, item.preferredImageVisibility != .visible {
            item.preferredImageVisibility = .visible
        }
        item.submenu?.restoreItemImageVisibility()
    }
}
