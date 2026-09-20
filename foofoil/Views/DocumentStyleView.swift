//
//  DocumentStyleView.swift
//  foofoil
//
//  Created by tolg on 2026/9/20.
//

import AppKit
import SwiftUI

/// 文档样式面板内容：背景颜色（所有文档箔）+ 文字颜色、字体、行间距、段落间距（无排版文档内容）。
/// 改动直接写进当前箔的 AppState，随历史一起保存；`nil` 表示沿用该通道自己的默认样式。
struct DocumentStyleView: View {
    @ObservedObject var appState: AppState

    @State private var catalog: DocumentFontCatalog.Catalog?
    @State private var chineseOnly = false
    @State private var query = ""
    @State private var selectedFamily: String?

    private let lineHeightRange: ClosedRange<Double> = 0.8...2.6
    private let paragraphSpacingRange: ClosedRange<Double> = 0...2.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if appState.supportsContentBackgroundColor {
                section(NSLocalizedString("Background Color", comment: "")) {
                    colorRow(
                        color: backgroundBinding,
                        isCustom: appState.backgroundColorHex != nil,
                        reset: { appState.backgroundColorHex = nil }
                    )
                }
            }

            if appState.supportsDocumentTextStyling {
                section(NSLocalizedString("Text Color", comment: "")) {
                    colorRow(
                        color: textColorBinding,
                        isCustom: appState.textColorHex != nil,
                        reset: { appState.textColorHex = nil }
                    )
                }

                fontSection

                section(NSLocalizedString("Line Spacing", comment: "")) {
                    spacingRow(
                        binding: lineSpacingBinding,
                        range: lineHeightRange,
                        defaultStart: 1.6,
                        valueLabel: { String(format: "%.2f×", $0) }
                    )
                }

                section(NSLocalizedString("Paragraph Spacing", comment: "")) {
                    spacingRow(
                        binding: paragraphSpacingBinding,
                        range: paragraphSpacingRange,
                        defaultStart: 0.6,
                        valueLabel: { String(format: "%.2f em", $0) }
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(minWidth: 360, idealWidth: 380, minHeight: 420)
        .task {
            let loaded = await DocumentFontCatalog.load()
            catalog = loaded
            selectedFamily = resolvedFamily(in: loaded)
            chineseOnly = SettingsStore.shared.documentFontsChineseOnly
                ?? DocumentFontCatalog.prefersChineseFonts(text: appState.text)
        }
    }

    // MARK: - 字体

    private var fontSection: some View {
        section(NSLocalizedString("Font", comment: "")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(NSLocalizedString("Chinese Fonts Only", comment: ""), isOn: $chineseOnly)
                    .toggleStyle(.checkbox)
                    .onChange(of: chineseOnly) { _, newValue in
                        SettingsStore.shared.documentFontsChineseOnly = newValue
                    }

                TextField(NSLocalizedString("Search Fonts", comment: ""), text: $query)
                    .textFieldStyle(.roundedBorder)

                familyList

                HStack(spacing: 8) {
                    Picker(NSLocalizedString("Typeface", comment: ""), selection: typefaceBinding) {
                        ForEach(selectedFamilyMembers, id: \.postScriptName) { member in
                            Text(member.typeface).tag(member.postScriptName)
                        }
                    }
                    .frame(maxWidth: 200)
                    .disabled(selectedFamilyMembers.count < 2)

                    Button(NSLocalizedString("Default", comment: "")) {
                        appState.documentFontName = nil
                    }
                    .disabled(appState.documentFontName == nil)
                }

                sizeRow
            }
        }
    }

    private var familyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visibleFamilies) { family in
                    Button {
                        select(family: family)
                    } label: {
                        HStack(spacing: 6) {
                            Text(family.displayName)
                                .lineLimit(1)
                                .font(previewFont(for: family))
                            Spacer(minLength: 0)
                            if family.name == selectedFamily {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .background(family.name == selectedFamily ? Color.accentColor.opacity(0.15) : .clear)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: 150)
        .background(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
    }

    private var sizeRow: some View {
        // 文本/Markdown 调字号（点），扩展文档正文只有纯文字缩放，用同一个滑杆按百分比展示。
        HStack(spacing: 8) {
            Text(NSLocalizedString("Size", comment: ""))
            if appState.isExtensionDocument {
                Slider(
                    value: $appState.documentZoom,
                    in: AppState.minDocumentZoom...AppState.maxDocumentZoom,
                    onEditingChanged: stylingEditingChanged
                )
                Text("\(Int((appState.documentZoom * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            } else {
                Slider(
                    value: Binding(
                        get: { appState.textFontSize },
                        set: { appState.textFontSize = $0.rounded() }
                    ),
                    in: AppState.minTextFontSize...AppState.maxTextFontSize,
                    step: 1,
                    onEditingChanged: stylingEditingChanged
                )
                Text("\(Int(appState.textFontSize)) pt")
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }

    // MARK: - 颜色与间距

    private func colorRow(color: Binding<Color>, isCustom: Bool, reset: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            ColorPicker(NSLocalizedString("Color", comment: ""), selection: color, supportsOpacity: true)
                .labelsHidden()
            Text(NSLocalizedString(isCustom ? "Custom" : "Default", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(NSLocalizedString("Default", comment: ""), action: reset)
                .disabled(!isCustom)
        }
    }

    /// 间距行：未自定义时只显示「默认」，点「自定义」给一个起始值再出现滑杆。
    private func spacingRow(
        binding: Binding<Double?>,
        range: ClosedRange<Double>,
        defaultStart: Double,
        valueLabel: @escaping (Double) -> String
    ) -> some View {
        HStack(spacing: 8) {
            if let value = binding.wrappedValue {
                Slider(
                    value: Binding(get: { value }, set: { binding.wrappedValue = $0 }),
                    in: range,
                    onEditingChanged: stylingEditingChanged
                )
                Text(valueLabel(value))
                    .monospacedDigit()
                    .frame(width: 68, alignment: .trailing)
                Button(NSLocalizedString("Default", comment: "")) { binding.wrappedValue = nil }
            } else {
                Text(NSLocalizedString("Default", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(NSLocalizedString("Custom", comment: "")) { binding.wrappedValue = defaultStart }
            }
        }
    }

    /// 拖动中的每一帧都不写历史，松手时补一次保存。
    private func stylingEditingChanged(_ editing: Bool) {
        appState.isAdjustingDocumentStyling = editing
        if !editing {
            appState.saveState()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - 绑定

    private var backgroundBinding: Binding<Color> {
        Binding(
            get: {
                appState.contentBackgroundColor.map(Color.init(nsColor:))
                    ?? Color(nsColor: .windowBackgroundColor)
            },
            set: { appState.backgroundColorHex = Self.hex(from: $0) }
        )
    }

    private var textColorBinding: Binding<Color> {
        Binding(
            get: {
                appState.documentTextColor.map(Color.init(nsColor:))
                    ?? Color(nsColor: .labelColor)
            },
            set: { appState.textColorHex = Self.hex(from: $0) }
        )
    }

    private var lineSpacingBinding: Binding<Double?> {
        Binding(get: { appState.documentLineSpacing }, set: { appState.documentLineSpacing = $0 })
    }

    private var paragraphSpacingBinding: Binding<Double?> {
        Binding(get: { appState.documentParagraphSpacing }, set: { appState.documentParagraphSpacing = $0 })
    }

    private var typefaceBinding: Binding<String> {
        Binding(
            get: { appState.documentFontName ?? selectedFamilyMembers.first?.postScriptName ?? "" },
            set: { appState.documentFontName = $0.isEmpty ? nil : $0 }
        )
    }

    private static func hex(from color: Color) -> String? {
        NSColor(color).usingColorSpace(.sRGB)?.toHex()
    }

    // MARK: - 字体列表

    private var visibleFamilies: [DocumentFontCatalog.Family] {
        guard let catalog else { return [] }
        let families = catalog.families(chineseOnly: chineseOnly)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return families }
        // 中文字体显示中文名，搜索时同时匹配中文显示名与系统字族名。
        return families.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed)
                || $0.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var selectedFamilyMembers: [DocumentFontCatalog.Member] {
        guard let catalog, let selectedFamily else { return [] }
        return catalog.families.first { $0.name == selectedFamily }?.members ?? []
    }

    private func resolvedFamily(in catalog: DocumentFontCatalog.Catalog) -> String? {
        guard let name = appState.documentFontName, let font = NSFont(name: name, size: 12) else { return nil }
        return font.familyName.flatMap { family in
            catalog.families.contains { $0.name == family } ? family : nil
        }
    }

    private func previewFont(for family: DocumentFontCatalog.Family) -> Font {
        guard let member = family.members.first, let font = NSFont(name: member.postScriptName, size: 12) else {
            return .system(size: 12)
        }
        return Font(font)
    }

    /// 选中的是字族：换族时尽量保留当前字型（Bold 等），找不到就取该族第一个字型。
    private func select(family: DocumentFontCatalog.Family) {
        selectedFamily = family.name
        if let current = appState.documentFontName,
           family.members.contains(where: { $0.postScriptName == current }) {
            return
        }
        let currentFace = appState.documentFontName
            .flatMap { NSFont(name: $0, size: 12)?.fontDescriptor.object(forKey: .face) as? String }
        if let currentFace, let match = family.members.first(where: { $0.typeface == currentFace }) {
            appState.documentFontName = match.postScriptName
            return
        }
        appState.documentFontName = family.members.first?.postScriptName
    }
}
