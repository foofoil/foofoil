//  DocumentPageInjection.swift
//  foofoil
//
//  Created by tolg on 2026/9/18.
//

import AppKit

/// 宿主对文档页面（网页、扩展文档/电子书）的样式覆盖：
/// 自选内容背景色、文字颜色与字体写在 html/body 的内联样式上——CSSOM 写入不受页面 CSP 的 style-src 限制，
/// 清除时也能按元素、按属性还原宿主改动前的内联值。
/// 页面把不透明背景画在正文容器（而非 html/body）上时，宿主无法覆盖该容器。
enum DocumentPageInjection {
    /// 需要覆盖的样式；`nil` 表示撤销宿主对该属性的覆盖、恢复页面自有样式。
    struct Overrides: Equatable {
        var backgroundColorHex: String?
        var textColorHex: String?
        var fontFamily: String?
        var lineHeightMultiple: Double?
        var paragraphSpacingMultiple: Double?

        var isEmpty: Bool {
            backgroundColorHex == nil && textColorHex == nil && fontFamily == nil
                && lineHeightMultiple == nil && paragraphSpacingMultiple == nil
        }
    }

    /// 所有会被覆盖的 CSS 属性；脚本对未出现在本次覆盖里的属性执行还原。
    /// 后三个是自定义属性：正文容器由文档自身样式控制行高与段距，只有自定义属性才能被那些规则消费。
    private static let coveredProperties = [
        "background-color", "background-image", "color", "font-family", "line-height",
        documentLineHeightVariable, documentParagraphSpacingVariable, documentFontFamilyVariable
    ]

    /// 扩展文档读取的自定义属性；文档样式可据此覆盖自己的排版。
    static let documentLineHeightVariable = "--foofoil-document-line-height"
    static let documentParagraphSpacingVariable = "--foofoil-document-paragraph-spacing"
    static let documentFontFamilyVariable = "--foofoil-document-font-family"

    /// 注入脚本。
    static func script(_ overrides: Overrides) -> String {
        var declarations: [String] = []
        // 自选背景色要盖住页面壁纸，否则背景图会整块遮住选色。
        if let background = validHex(overrides.backgroundColorHex) {
            declarations.append("\"background-color\": \"\(background)\"")
            declarations.append("\"background-image\": \"none\"")
        }
        if let text = validHex(overrides.textColorHex) {
            declarations.append("\"color\": \"\(text)\"")
        }
        if let fontFamily = overrides.fontFamily, !fontFamily.isEmpty {
            declarations.append("\"font-family\": \(jsString(fontFamily))")
            declarations.append("\"\(documentFontFamilyVariable)\": \(jsString(fontFamily))")
        }
        if let lineHeight = overrides.lineHeightMultiple {
            // 行高是纯倍数：内联值给不认自定义属性的文档兜底，自定义属性给扩展文档自己的排版规则用。
            declarations.append("\"line-height\": \"\(cssNumber(lineHeight))\"")
            declarations.append("\"\(documentLineHeightVariable)\": \"\(cssNumber(lineHeight))\"")
        }
        if let paragraphSpacing = overrides.paragraphSpacingMultiple {
            declarations.append("\"\(documentParagraphSpacingVariable)\": \"\(cssNumber(paragraphSpacing))em\"")
        }
        return template
            .replacingOccurrences(of: "__FOOFOIL_PROPERTIES__", with: coveredProperties.map { "\"\($0)\"" }.joined(separator: ", "))
            .replacingOccurrences(of: "__FOOFOIL_OVERRIDES__", with: "{\(declarations.joined(separator: ", "))}")
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

    /// 数值转 CSS：去掉多余的尾随零，避免 1.6000000000000001 这类浮点噪声进入样式。
    private static func cssNumber(_ value: Double) -> String {
        String(format: "%.2f", value)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
    }

    /// 字体名可能带引号与空格，按 JSON 规则转义后作为 JS 字符串字面量。
    private static func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data()
        let encoded = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(encoded.dropFirst().dropLast())
    }

    private static let template = """
    (function () {
      var overrides = __FOOFOIL_OVERRIDES__;
      var properties = [__FOOFOIL_PROPERTIES__];
      var targets = [document.documentElement, document.body];
      function restore(element, property, saved) {
        if (saved.value) { element.style.setProperty(property, saved.value, saved.priority); }
        else { element.style.removeProperty(property); }
        if (!saved.hadStyleAttribute && element.getAttribute('style') === '') {
          element.removeAttribute('style');
        }
      }
      for (var i = 0; i < targets.length; i++) {
        var element = targets[i];
        if (!element) { continue; }
        var saved = element.__foofoilPageOverrides;
        if (!saved) { saved = {}; element.__foofoilPageOverrides = saved; }
        for (var j = 0; j < properties.length; j++) {
          var property = properties[j];
          var value = overrides[property] || null;
          if (value) {
            if (!saved[property]) {
              saved[property] = {
                value: element.style.getPropertyValue(property),
                priority: element.style.getPropertyPriority(property),
                hadStyleAttribute: element.hasAttribute('style')
              };
            }
            element.style.setProperty(property, value, 'important');
          } else if (saved[property]) {
            restore(element, property, saved[property]);
            delete saved[property];
          }
        }
      }
    })();
    """
}
