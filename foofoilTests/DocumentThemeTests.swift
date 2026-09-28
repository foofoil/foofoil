//
//  DocumentThemeTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/9/28.
//

import AppKit
import Foundation
import Testing
@testable import foofoil

@MainActor
@Suite(.serialized)
struct DocumentThemeTests {
    /// 预设主题色彩合规性：所有预设在亮暗两套外观下均为合法 sRGB 色彩，且对比度均达到 WCAG AAA 标杆（>= 7:1）。
    @Test func presetsHaveValidColorsAndHighContrast() throws {
        let catalog = DocumentThemeCatalog.shared
        #expect(catalog.presets.count >= 6, "预设主题数量不足")

        for preset in catalog.presets {
            #expect(!preset.displayName.isEmpty)

            // 亮色外观
            let lightBg = try #require(NSColor(hex: preset.lightBackgroundHex), "亮色背景色非法：\(preset.lightBackgroundHex)")
            let lightFg = try #require(NSColor(hex: preset.lightTextHex), "亮色前景色非法：\(preset.lightTextHex)")
            let lightContrast = contrastRatio(between: lightBg, and: lightFg)
            #expect(lightContrast >= 7.0, "\(preset.name) 亮色对比度过低：\(lightContrast):1")

            // 暗色外观
            let darkBg = try #require(NSColor(hex: preset.darkBackgroundHex), "暗色背景色非法：\(preset.darkBackgroundHex)")
            let darkFg = try #require(NSColor(hex: preset.darkTextHex), "暗色前景色非法：\(preset.darkTextHex)")
            let darkContrast = contrastRatio(between: darkBg, and: darkFg)
            #expect(darkContrast >= 7.0, "\(preset.name) 暗色对比度过低：\(darkContrast):1")
        }
    }

    /// 应用主题时只更新前景色、背景色与主题标识，不干扰其他属性。
    @Test func applyDocumentThemeSetsColorsAndThemeId() throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }

        state.text = "正文内容"
        let parchment = try #require(DocumentThemeCatalog.shared.theme(for: "parchment"))

        // 在亮色模式下应用
        state.applyDocumentTheme(parchment, isDark: false)
        #expect(state.documentThemeId == "parchment")
        #expect(state.backgroundColorHex == parchment.lightBackgroundHex)
        #expect(state.textColorHex == parchment.lightTextHex)

        // 在暗色模式下应用
        state.applyDocumentTheme(parchment, isDark: true)
        #expect(state.documentThemeId == "parchment")
        #expect(state.backgroundColorHex == parchment.darkBackgroundHex)
        #expect(state.textColorHex == parchment.darkTextHex)
    }

    /// 选中主题后，若修改了背景色或点击了重置，必须取消选中主题。
    @Test func changingBackgroundColorDeselectsTheme() throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.text = "正文"

        let minimal = try #require(DocumentThemeCatalog.shared.theme(for: "minimal"))
        state.applyDocumentTheme(minimal, isDark: false)
        #expect(state.documentThemeId == "minimal")

        // 手动修改背景色
        state.backgroundColorHex = "#123456"
        #expect(state.documentThemeId == nil, "手动修改背景色后未取消选中主题")

        // 重新选中主题后再点击重置默认背景色
        state.applyDocumentTheme(minimal, isDark: false)
        #expect(state.documentThemeId == "minimal")
        state.backgroundColorHex = nil
        #expect(state.documentThemeId == nil, "重置背景色后未取消选中主题")
    }

    /// 选中主题后，若修改了文字颜色或点击了重置，必须取消选中主题。
    @Test func changingTextColorDeselectsTheme() throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.text = "正文"

        let bamboo = try #require(DocumentThemeCatalog.shared.theme(for: "bamboo"))
        state.applyDocumentTheme(bamboo, isDark: false)
        #expect(state.documentThemeId == "bamboo")

        // 手动修改文字颜色
        state.textColorHex = "#654321"
        #expect(state.documentThemeId == nil, "手动修改文字颜色后未取消选中主题")

        // 重新选中主题后再点击重置默认文字颜色
        state.applyDocumentTheme(bamboo, isDark: false)
        #expect(state.documentThemeId == "bamboo")
        state.textColorHex = nil
        #expect(state.documentThemeId == nil, "重置文字颜色后未取消选中主题")
    }

    /// 系统外观在明暗间切换时，保持选中的主题并自动切换到该主题对应的亮暗版本色彩。
    @Test func appearanceChangeAdaptsThemeColors() throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.text = "正文"

        let dusk = try #require(DocumentThemeCatalog.shared.theme(for: "dusk"))
        state.applyDocumentTheme(dusk, isDark: false)
        #expect(state.documentThemeId == "dusk")
        #expect(state.backgroundColorHex == dusk.lightBackgroundHex)
        #expect(state.textColorHex == dusk.lightTextHex)

        // 切换到暗色外观
        state.adaptDocumentColorsToAppearanceChange(toDarkAppearance: true)
        #expect(state.documentThemeId == "dusk", "外观切换后主题应保持选中")
        #expect(state.backgroundColorHex == dusk.darkBackgroundHex)
        #expect(state.textColorHex == dusk.darkTextHex)

        // 切换回亮色外观
        state.adaptDocumentColorsToAppearanceChange(toDarkAppearance: false)
        #expect(state.documentThemeId == "dusk", "外观切换回亮色后主题应保持选中")
        #expect(state.backgroundColorHex == dusk.lightBackgroundHex)
        #expect(state.textColorHex == dusk.lightTextHex)
    }

    /// 用户自建主题的保存、明暗成对推导、持久化与删除。
    @Test func customThemeCreationPersistenceAndDeletion() throws {
        let catalog = DocumentThemeCatalog.shared
        let initialCustomCount = catalog.customThemes.count

        // 用户在浅色外观下设定了自定义色彩
        let created = catalog.addCustomTheme(
            name: "测试雅致暖黄",
            currentBackgroundHex: "#FAF3D2",
            currentTextHex: "#4A3508",
            isCurrentlyDark: false
        )
        defer { catalog.deleteCustomTheme(id: created.id) }

        #expect(created.isCustom)
        #expect(created.name == "测试雅致暖黄")
        #expect(created.lightBackgroundHex == "#FAF3D2")
        #expect(created.lightTextHex == "#4A3508")
        // 暗色外观通过明度镜像自动推导，具备色彩反转与高对比
        #expect(!created.darkBackgroundHex.isEmpty)
        #expect(!created.darkTextHex.isEmpty)

        #expect(catalog.customThemes.count == initialCustomCount + 1)
        #expect(SettingsStore.shared.customDocumentThemes.contains { $0.id == created.id })

        let found = catalog.theme(for: created.id)
        #expect(found?.id == created.id)

        // 删除自定义主题
        catalog.deleteCustomTheme(id: created.id)
        #expect(catalog.theme(for: created.id) == nil)
        #expect(SettingsStore.shared.customDocumentThemes.contains { $0.id == created.id } == false)
    }

    /// 历史数据库中 documentThemeId 的往返读写与恢复。
    @Test func themePersistenceRoundTripsThroughHistoryDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-theme-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("history.sqlite3")
        let database = try HistoryDatabase(databaseURL: databaseURL)

        let config = WindowConfig(
            id: UUID(),
            text: "正文测试",
            backgroundColorHex: "#F5EFE0",
            textColorHex: "#382E24",
            documentThemeId: "parchment"
        )
        try database.upsert(config)

        let loaded = try #require(try database.config(id: config.id))
        #expect(loaded.documentThemeId == "parchment")
        #expect(loaded.backgroundColorHex == "#F5EFE0")
        #expect(loaded.textColorHex == "#382E24")

        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.loadConfig(loaded)
        #expect(state.documentThemeId == "parchment")
        #expect(state.backgroundColorHex == "#F5EFE0")
        #expect(state.textColorHex == "#382E24")
    }

    /// 空白箔在用户输入内容前没有默认主题，且不是文档类型。
    @Test func blankFoilHasNoThemeAndIsNotDocument() throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }

        #expect(state.isBlank)
        #expect(!state.supportsContentBackgroundColor)
        #expect(!state.supportsDocumentTextStyling)
        #expect(state.documentThemeId == nil)
        #expect(state.backgroundColorHex == nil)
        #expect(state.textColorHex == nil)
        #expect(state.contentBackgroundColor == nil)
        #expect(state.documentTextColor == nil)
    }

    /// 用户首次输入内容时成为文档类型，并自动应用默认文档样式「素白」。
    @Test func enteringContentMakesDocumentAndAppliesMinimalTheme() throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }

        #expect(state.isBlank)
        state.text = "开始输入正文"
        #expect(!state.isBlank)
        #expect(state.supportsContentBackgroundColor)
        #expect(state.supportsDocumentTextStyling)

        let defaultTheme = DocumentThemeCatalog.defaultTheme
        let isDark = AppState.isDarkMode()
        #expect(defaultTheme.id == "minimal")
        #expect(state.documentThemeId == "minimal")
        #expect(state.backgroundColorHex == defaultTheme.backgroundHex(isDark: isDark))
        #expect(state.textColorHex == defaultTheme.textHex(isDark: isDark))
    }

    /// 重置箔片内容时回到空白箔状态，清除主题与自选色彩。
    @Test func resetContentClearsThemeForBlankFoil() throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }

        state.text = "正文"
        let parchment = try #require(DocumentThemeCatalog.shared.theme(for: "parchment"))
        state.applyDocumentTheme(parchment, isDark: false)
        #expect(state.documentThemeId == "parchment")

        state.resetContent()
        #expect(state.isBlank)
        #expect(!state.supportsContentBackgroundColor)
        #expect(!state.supportsDocumentTextStyling)
        #expect(state.documentThemeId == nil)
        #expect(state.backgroundColorHex == nil)
        #expect(state.textColorHex == nil)
    }

    /// 文档有内容时，单独恢复背景色或文字颜色到默认值，当两色均达到默认时自动重设主题标识为「素白」。
    @Test func resetColorsToDefaultRestoresMinimalTheme() throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }

        state.text = "正文"
        let defaultTheme = DocumentThemeCatalog.defaultTheme
        let isDark = false
        state.applyDocumentTheme(defaultTheme, isDark: isDark)
        #expect(state.documentThemeId == "minimal")

        // 自定义背景色
        state.backgroundColorHex = "#FF0000"
        #expect(state.documentThemeId == nil)

        // 恢复默认背景色，由于文字颜色仍为默认值，自动恢复素白主题
        state.resetBackgroundColorToDefault(isDark: isDark)
        #expect(state.backgroundColorHex == defaultTheme.backgroundHex(isDark: isDark))
        #expect(state.documentThemeId == "minimal")

        // 自定义文字颜色
        state.textColorHex = "#00FF00"
        #expect(state.documentThemeId == nil)

        // 恢复默认文字颜色，由于背景色为默认值，自动恢复素白主题
        state.resetTextColorToDefault(isDark: isDark)
        #expect(state.textColorHex == defaultTheme.textHex(isDark: isDark))
        #expect(state.documentThemeId == "minimal")
    }

    // MARK: - 对比度计算辅助

    private func contrastRatio(between c1: NSColor, and c2: NSColor) -> CGFloat {
        let l1 = relativeLuminance(of: c1)
        let l2 = relativeLuminance(of: c2)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private func relativeLuminance(of color: NSColor) -> CGFloat {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
        func channelLuminance(_ val: CGFloat) -> CGFloat {
            val <= 0.04045 ? val / 12.92 : pow((val + 0.055) / 1.055, 2.4)
        }
        let r = channelLuminance(srgb.redComponent)
        let g = channelLuminance(srgb.greenComponent)
        let b = channelLuminance(srgb.blueComponent)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}
