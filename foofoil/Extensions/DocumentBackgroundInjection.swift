//  DocumentBackgroundInjection.swift
//  foofoil
//
//  Created by tolg on 2026/9/18.
//

import AppKit

/// 网页与扩展文档两条 WKWebView 通道共用的内容背景注入：
/// 自选背景色写在 html/body 的内联样式上——CSSOM 写入不受页面 CSP 的 style-src 限制，
/// 清除时也能按元素还原宿主改动前的内联样式。
/// 扩展文档若把不透明背景画在正文容器（而非 html/body）上，宿主无法覆盖该容器。
enum DocumentBackgroundInjection {
    /// 注入脚本；`hex` 为 nil 或非法时还原页面自有背景。
    static func script(hex: String?) -> String {
        let color = validHex(hex).map { "\"\($0)\"" } ?? "null"
        return template.replacingOccurrences(of: "__FOOFOIL_BACKGROUND_COLOR__", with: color)
    }

    /// 页面外观：自选背景偏亮时用浅色外观，偏暗时用深色外观，
    /// 让页面自身的 `CanvasText`、`prefers-color-scheme` 配色与背景保持对比；
    /// 未选背景色时返回 nil，页面跟随系统外观。
    static func appearance(hex: String?) -> NSAppearance? {
        guard let hex = validHex(hex), let color = NSColor(hex: hex)?.usingColorSpace(.sRGB) else {
            return nil
        }
        // sRGB 加权亮度：只判断背景属于浅色还是深色，不做色调还原。
        let luminance = 0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
        return NSAppearance(named: luminance >= 0.5 ? .aqua : .darkAqua)
    }

    /// 只接受 `NSColor.toHex()` 的输出形态，脚本里可直接作为 CSS 颜色字面量。
    private static func validHex(_ hex: String?) -> String? {
        guard let hex,
              hex.range(of: "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$", options: .regularExpression) != nil else {
            return nil
        }
        return hex
    }

    private static let template = """
    (function () {
      var color = __FOOFOIL_BACKGROUND_COLOR__;
      var targets = [document.documentElement, document.body];
      function restore(element, property, value, priority) {
        if (value) { element.style.setProperty(property, value, priority); }
        else { element.style.removeProperty(property); }
      }
      for (var i = 0; i < targets.length; i++) {
        var element = targets[i];
        if (!element) { continue; }
        var saved = element.__foofoilDocumentBackground;
        if (color) {
          if (!saved) {
            saved = {
              color: element.style.getPropertyValue('background-color'),
              colorPriority: element.style.getPropertyPriority('background-color'),
              image: element.style.getPropertyValue('background-image'),
              imagePriority: element.style.getPropertyPriority('background-image'),
              hadStyleAttribute: element.hasAttribute('style')
            };
            element.__foofoilDocumentBackground = saved;
          }
          element.style.setProperty('background-color', color, 'important');
          element.style.setProperty('background-image', 'none', 'important');
        } else if (saved) {
          restore(element, 'background-color', saved.color, saved.colorPriority);
          restore(element, 'background-image', saved.image, saved.imagePriority);
          if (!saved.hadStyleAttribute && element.getAttribute('style') === '') {
            element.removeAttribute('style');
          }
          delete element.__foofoilDocumentBackground;
        }
      }
    })();
    """
}
