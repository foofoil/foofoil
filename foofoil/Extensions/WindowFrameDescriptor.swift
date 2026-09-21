//  WindowFrameDescriptor.swift
//  foofoil
//
//  Created by tolg on 2026/9/21.
//


import AppKit

extension NSWindow {
    /// 解析 `frameDescriptor` 字符串中的窗口框。
    ///
    /// AppKit 只保证该字符串能被 `setFrame(from:)` 消费，格式并未公开：常见为
    /// `x y 宽 高 屏幕x 屏幕y 屏幕宽 屏幕高`。这里只取前四个数值，附带或不附带屏幕框的写法都能解析，
    /// 并滤掉无法解析、非有限或非正的尺寸，避免把脏数据写进窗口框。
    /// 解析出的位置与尺寸都位于保存时的屏幕坐标系，跨屏恢复需再经 `constrainFrameRect(_:to:)` 夹取。
    nonisolated static func frameRect(fromDescriptor descriptor: String) -> NSRect? {
        let values = descriptor
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(4)
            .compactMap { Double($0) }
        guard values.count == 4, values.allSatisfy({ $0.isFinite }) else { return nil }
        let rect = NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
        // NSRect.width/height 取的是绝对值，这里必须看原始 size 才能识别负尺寸。
        guard rect.size.width > 0, rect.size.height > 0 else { return nil }
        return rect
    }
}
