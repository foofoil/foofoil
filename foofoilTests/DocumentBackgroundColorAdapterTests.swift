//  DocumentBackgroundColorAdapterTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/9/18.
//

import AppKit
import Testing
@testable import foofoil

@MainActor
@Suite
struct DocumentBackgroundColorAdapterTests {
    /// 明显的浅色在深色主题下换成同色相的深色：色相与饱和度不变，明度镜像。
    @Test func mirrorsClearlyLightColorsForDarkAppearance() throws {
        for hex in ["#F5EFE0", "#FFF9C4", "#E8F5E9", "#FFFFFF"] {
            let original = try #require(NSColor(hex: hex))
            let adapted = try #require(
                DocumentBackgroundColorAdapter.adaptedColor(original, forDarkAppearance: true),
                "\(hex) 未按深色主题适配"
            )
            #expect(lightness(of: adapted) <= DocumentBackgroundColorAdapter.darkThreshold)
            #expect(abs(hue(of: adapted) - hue(of: original)) < 0.02, "\(hex) 适配后色相改变")
            // 镜像是对称的：换回浅色主题即得到原色。
            let restored = try #require(
                DocumentBackgroundColorAdapter.adaptedColor(adapted, forDarkAppearance: false)
            )
            #expect(isClose(restored, to: original), "\(hex) 镜像不可逆")
        }
    }

    /// 明显的深色在浅色主题下换成同色相的浅色。
    @Test func mirrorsClearlyDarkColorsForLightAppearance() throws {
        for hex in ["#1C1C1E", "#123456", "#2B2016", "#000000"] {
            let original = try #require(NSColor(hex: hex))
            let adapted = try #require(
                DocumentBackgroundColorAdapter.adaptedColor(original, forDarkAppearance: false),
                "\(hex) 未按浅色主题适配"
            )
            #expect(lightness(of: adapted) >= DocumentBackgroundColorAdapter.lightThreshold)
            #expect(abs(hue(of: adapted) - hue(of: original)) < 0.02, "\(hex) 适配后色相改变")
            let restored = try #require(
                DocumentBackgroundColorAdapter.adaptedColor(adapted, forDarkAppearance: true)
            )
            #expect(isClose(restored, to: original), "\(hex) 镜像不可逆")
        }
    }

    /// 中间色对明暗主题都可读，与主题相符的颜色也不需要改。
    @Test func leavesMatchingAndAmbiguousColorsUnchanged() throws {
        for hex in ["#808080", "#FF0000", "#0969DA", "#FFFF00"] {
            let color = try #require(NSColor(hex: hex))
            #expect(DocumentBackgroundColorAdapter.adaptedColor(color, forDarkAppearance: true) == nil, "\(hex)")
            #expect(DocumentBackgroundColorAdapter.adaptedColor(color, forDarkAppearance: false) == nil, "\(hex)")
        }
        for hex in ["#F5EFE0", "#FFFFFF"] {
            let color = try #require(NSColor(hex: hex))
            #expect(DocumentBackgroundColorAdapter.adaptedColor(color, forDarkAppearance: false) == nil, "\(hex)")
        }
        for hex in ["#1C1C1E", "#000000"] {
            let color = try #require(NSColor(hex: hex))
            #expect(DocumentBackgroundColorAdapter.adaptedColor(color, forDarkAppearance: true) == nil, "\(hex)")
        }
    }

    @Test func keepsTransparency() throws {
        let original = try #require(NSColor(hex: "#F5EFE080"))
        let adapted = try #require(
            DocumentBackgroundColorAdapter.adaptedColor(original, forDarkAppearance: true)
        )
        #expect(abs(adapted.alphaComponent - 0.5) < 0.01)
        #expect(adapted.usingColorSpace(.sRGB)?.toHex()?.hasSuffix("80") == true)
    }

    private func lightness(of color: NSColor) -> CGFloat {
        let srgb = color.usingColorSpace(.sRGB)!
        let components = [
            srgb.redComponent,
            srgb.greenComponent,
            srgb.blueComponent
        ]
        return (components.max()! + components.min()!) / 2
    }

    private func hue(of color: NSColor) -> CGFloat {
        var hue: CGFloat = 0
        color.usingColorSpace(.sRGB)?.getHue(&hue, saturation: nil, brightness: nil, alpha: nil)
        return hue
    }

    /// 8 位量化后的相等判断：镜像会经过一轮 sRGB 取整。
    private func isClose(_ lhs: NSColor, to rhs: NSColor) -> Bool {
        guard let left = lhs.usingColorSpace(.sRGB), let right = rhs.usingColorSpace(.sRGB) else {
            return false
        }
        return abs(left.redComponent - right.redComponent) < 0.01
            && abs(left.greenComponent - right.greenComponent) < 0.01
            && abs(left.blueComponent - right.blueComponent) < 0.01
            && abs(left.alphaComponent - right.alphaComponent) < 0.01
    }
}
