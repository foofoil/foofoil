//  DocumentBackgroundColorAdapter.swift
//  foofoil
//
//  Created by tolg on 2026/9/18.
//

import AppKit

/// 文档内容背景色的明暗镜像：系统外观切换时，把与目标主题明显不符的自选背景色换成同色相的深浅版本。
/// 只翻 HSL 明度（L' = 1 - L），色相、饱和度与透明度都不变，因此来回切换是同一个变换、互为逆运算。
enum DocumentBackgroundColorAdapter {
    /// 「明显偏亮 / 明显偏暗」的 HSL 明度阈值；中间色对明暗主题都可读，不做改动。
    static let lightThreshold: CGFloat = 0.7
    static let darkThreshold: CGFloat = 0.3

    /// 颜色与目标主题明显不符时返回镜像色；颜色本身不明显，或已与目标主题相符时返回 nil。
    static func adaptedColor(_ color: NSColor, forDarkAppearance isDark: Bool) -> NSColor? {
        guard let srgb = color.usingColorSpace(.sRGB), let components = HSB(srgb) else { return nil }
        let isClearlyLight = components.lightness >= lightThreshold
        let isClearlyDark = components.lightness <= darkThreshold
        guard isDark ? isClearlyLight : isClearlyDark else { return nil }
        return components.mirroredLightness
    }
}

/// HSB 分量与其 HSL 明度的镜像：AppKit 只提供 HSB，明度判断与镜像都换成 HSL 明度，
/// 以免「纯蓝」这类高饱和色被误判成亮色、或在镜像时丢掉色相。
private struct HSB {
    let hue: CGFloat
    let saturation: CGFloat
    let brightness: CGFloat
    let alpha: CGFloat

    init?(_ color: NSColor) {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        self.init(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
    }

    private init(hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
        self.alpha = alpha
    }

    /// HSL 明度：中间灰为 0.5，纯色按自身最亮分量折算，因此受饱和度影响。
    var lightness: CGFloat {
        brightness * (1 - saturation / 2)
    }

    /// 明度镜像后的颜色：色相与 HSL 饱和度不变，透明度保留，结果始终在 sRGB 色域内。
    var mirroredLightness: NSColor {
        let lightness = self.lightness
        let hslSaturation = (lightness <= 0 || lightness >= 1)
            ? 0
            : (brightness - lightness) / min(lightness, 1 - lightness)
        let mirrored = 1 - lightness
        let mirroredBrightness = mirrored + hslSaturation * min(mirrored, 1 - mirrored)
        let mirroredSaturation = mirroredBrightness <= 0
            ? 0
            : min(1, 2 * (1 - mirrored / mirroredBrightness))
        let rgb = Self.rgb(hue: hue, saturation: mirroredSaturation, brightness: mirroredBrightness)
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
    }

    private static func rgb(
        hue: CGFloat,
        saturation: CGFloat,
        brightness: CGFloat
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let chroma = brightness * saturation
        let position = (hue - hue.rounded(.down)) * 6
        let second = chroma * (1 - abs(position.truncatingRemainder(dividingBy: 2) - 1))
        let base = brightness - chroma
        switch Int(position) {
        case 0: return (chroma + base, second + base, base)
        case 1: return (second + base, chroma + base, base)
        case 2: return (base, chroma + base, second + base)
        case 3: return (base, second + base, chroma + base)
        case 4: return (second + base, base, chroma + base)
        default: return (chroma + base, base, second + base)
        }
    }
}
