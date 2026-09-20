//  DocumentFontCatalog.swift
//  foofoil
//
//  Created by tolg on 2026/9/18.
//

import AppKit
import CoreText

/// 系统已安装字体的目录，供文档样式面板选择。
/// 列表按字族给出，字族内的字型（Regular/Bold/…）来自 `NSFontManager.availableMembersOfFontFamily`；
/// 「只显示中文字体」按字体是否覆盖常用汉字筛选，而不是只看字体自称的语言。
@MainActor
enum DocumentFontCatalog {
    /// 一个字族及其可选字型。
    struct Family: Identifiable, Hashable {
        let name: String
        let members: [Member]

        var id: String { name }
    }

    /// 字族下的一个字型：PostScript 名是持久化与解析字体时用的稳定标识。
    struct Member: Identifiable, Hashable {
        let postScriptName: String
        let typeface: String

        var id: String { postScriptName }
    }

    /// 一次枚举的结果：字族列表 + 其中覆盖汉字的字族名。
    /// 面板打开时取一次，之后开关只做本地筛选。
    struct Catalog: Sendable {
        let families: [Family]
        let chineseFamilyNames: Set<String>

        func families(chineseOnly: Bool) -> [Family] {
            chineseOnly ? families.filter { chineseFamilyNames.contains($0.name) } : families
        }
    }

    /// 枚举系统字体；汉字覆盖判定放到后台线程，避免面板打开时卡主线程。
    static func load() async -> Catalog {
        if let cachedCatalog { return cachedCatalog }
        let enumerated = NSFontManager.shared.availableFontFamilies.map { family in
            Family(name: family, members: members(of: family))
        }
        let catalog = await Task.detached(priority: .userInitiated) {
            Catalog(
                families: enumerated,
                chineseFamilyNames: Set(enumerated.filter { supportsChinese($0.members) }.map(\.name))
            )
        }.value
        cachedCatalog = catalog
        return catalog
    }

    /// 自动判定「优先列中文字体」：系统首选语言是中文，或当前箔正文含统一表意文字。
    /// 面板里用户手动切换后以设置为准（`SettingsStore.documentFontsChineseOnly`）。
    static func prefersChineseFonts(
        systemLanguages: [String] = Locale.preferredLanguages,
        text: String
    ) -> Bool {
        if systemLanguages.contains(where: { $0.hasPrefix("zh") }) { return true }
        return text.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
        }
    }

    static func members(of family: String) -> [Member] {
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        return members.compactMap { member in
            guard let postScriptName = member.first as? String else { return nil }
            let typeface = (member.count > 1 ? member[1] as? String : nil) ?? postScriptName
            return Member(postScriptName: postScriptName, typeface: typeface)
        }
    }

    /// 字体名 → 指定字号的字体；名字为空或解析失败时回退到文本通道的默认字体。
    static func font(named name: String?, size: CGFloat) -> NSFont {
        if let name, let font = NSFont(name: name, size: size) {
            return font
        }
        return defaultFont(size: size)
    }

    /// 文本通道的默认字体：现状的圆体系统字体。
    static func defaultFont(size: CGFloat) -> NSFont {
        let system = NSFont.systemFont(ofSize: size)
        guard let descriptor = system.fontDescriptor.withDesign(.rounded),
              let font = NSFont(descriptor: descriptor, size: size) else {
            return system
        }
        return font
    }

    /// 字体名 → 注入网页（电子书/扩展文档）的 font-family 值；未选择时返回 nil，保留文档自身排版。
    static func cssFontFamily(named name: String?) -> String? {
        guard let name, let font = NSFont(name: name, size: 12) else { return nil }
        return "\"\(font.familyName ?? name)\""
    }

    /// 字族是否覆盖常用汉字：按字形判定，符号字体、纯西文字体都会被排除。
    nonisolated private static func supportsChinese(_ members: [Member]) -> Bool {
        let sample = Array("汉字".utf16)
        return members.contains { member in
            guard let font = NSFont(name: member.postScriptName, size: 12) else { return false }
            var characters = sample
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            guard CTFontGetGlyphsForCharacters(font as CTFont, &characters, &glyphs, characters.count) else {
                return false
            }
            return glyphs.allSatisfy { $0 != 0 }
        }
    }

    private static var cachedCatalog: Catalog?
}
