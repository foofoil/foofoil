//
//  DocumentStyleView.swift
//  foofoil
//
//  Created by tolg on 2026/9/20.
//

import AppKit
import SwiftUI

/// 文档样式面板内容：外观与主题、背景颜色（所有文档箔）+ 文字颜色、字体、行间距、段落间距（无排版文档内容）。
/// 改动直接写进当前箔的 AppState，随历史一起保存；`nil` 表示沿用该通道自己的默认样式。
struct DocumentStyleView: View {
    @ObservedObject var appState: AppState

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themeCatalog = DocumentThemeCatalog.shared

    @State private var isShowingSaveThemePopover = false
    @State private var newThemeName = ""
    @State private var replacementThemeID = ""

    @State private var catalog: DocumentFontCatalog.Catalog?
    /// 字体列表是否按筛选条件收窄；代码内容筛选等宽字体，其余内容筛选中文字体。
    @State private var filterOnly = false
    @State private var query = ""
    @State private var selectedFamily: String?

    private let lineHeightRange: ClosedRange<Double> = 0.8...2.6
    private let paragraphSpacingRange: ClosedRange<Double> = 0...2.0

    /// 样式面板自身跟随系统；主题预览、取色默认值与保存操作使用文档实际外观。
    private var documentColorScheme: ColorScheme {
        appState.documentAppearance.colorScheme ?? colorScheme
    }

    private var isDocumentDark: Bool {
        appState.documentAppearance.isDark(systemIsDark: colorScheme == .dark)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                if appState.supportsContentBackgroundColor || appState.supportsDocumentTextStyling || appState.supportsContentSearch {
                    appearanceSection
                    themeSection
                }

                if appState.supportsContentBackgroundColor {
                    section(NSLocalizedString("Background Color", comment: "")) {
                        colorRow(
                            color: backgroundBinding,
                            statusText: backgroundStatusText,
                            isDefault: isBackgroundDefault,
                            reset: { appState.resetBackgroundColorToDefault(isDark: isDocumentDark) }
                        )
                    }
                }

                if appState.supportsContentSearch {
                    section(NSLocalizedString("Search Highlight Color", comment: "")) {
                        colorRow(
                            color: Binding(get: { Color(nsColor: NSColor(hex: appState.resolvedSearchHighlightHex) ?? .systemYellow) },
                                           set: { appState.searchHighlightHex = Self.hex(from: $0) }),
                            statusText: NSLocalizedString("Search Highlight Color", comment: ""),
                            isDefault: appState.searchHighlightHex == DocumentThemeCatalog.defaultTheme.highlightHex(isDark: isDocumentDark),
                            reset: { appState.searchHighlightHex = DocumentThemeCatalog.defaultTheme.highlightHex(isDark: isDocumentDark) },
                            supportsOpacity: false
                        )
                    }
                }

                if appState.supportsDocumentTextStyling {
                    section(NSLocalizedString("Text Color", comment: "")) {
                        colorRow(
                            color: textColorBinding,
                            statusText: textStatusText,
                            isDefault: isTextDefault,
                            reset: { appState.resetTextColorToDefault(isDark: isDocumentDark) }
                        )
                    }

                    fontSection

                    if appState.supportsDocumentSpacing {
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
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 360, idealWidth: 380)
        .task {
            let loaded = await DocumentFontCatalog.load()
            catalog = loaded
            selectedFamily = resolvedFamily(in: loaded)
            if appState.prefersMonospacedDocumentFonts {
                filterOnly = SettingsStore.shared.documentFontsMonospacedOnly ?? true
            } else {
                filterOnly = SettingsStore.shared.documentFontsChineseOnly
                    ?? DocumentFontCatalog.prefersChineseFonts(text: appState.text)
            }
        }
    }

    // MARK: - 外观与主题

    private var appearanceSection: some View {
        section(NSLocalizedString("Document Appearance", comment: "")) {
            DocumentAppearanceSegmentedControl(selection: appearanceBinding)
                .frame(maxWidth: .infinity)
        }
    }

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(NSLocalizedString("Theme", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    newThemeName = ""
                    replacementThemeID = ""
                    isShowingSaveThemePopover = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                        Text(NSLocalizedString("Save as Theme...", comment: ""))
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help(NSLocalizedString("Save current style as a theme", comment: ""))
                .sheet(isPresented: $isShowingSaveThemePopover) {
                    saveThemePopover
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(themeCatalog.allThemes) { theme in
                    themeCard(theme)
                }
            }
        }
    }

    private func themeCard(_ theme: DocumentTheme) -> some View {
        let isDark = isDocumentDark
        let isSelected = appState.documentThemeId == theme.id
        let bg = theme.backgroundColor(isDark: isDark)
        let fg = theme.textColor(isDark: isDark)

        return Button {
            appState.applyDocumentTheme(theme, isDark: isDark)
            if let catalog { selectedFamily = resolvedFamily(in: catalog) }
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(bg)
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                    Text("Aa")
                        .font(.system(size: 11, weight: .semibold, design: .serif))
                        .foregroundStyle(fg)
                }
                .frame(width: 24, height: 24)
                .environment(\.colorScheme, documentColorScheme)

                Text(theme.displayName)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if theme.isCustom {
                Button("Replace with Current Style") {
                    let updated = themeCatalog.addCustomTheme(name: theme.name,
                        currentBackgroundHex: appState.backgroundColorHex,
                        currentTextHex: appState.textColorHex, currentHighlightHex: appState.resolvedSearchHighlightHex, isCurrentlyDark: isDocumentDark,
                        typography: appState.currentThemeTypography, replacing: theme.id)
                    appState.applyDocumentTheme(updated, isDark: isDocumentDark)
                }
                Button(role: .destructive) {
                    if appState.documentThemeId == theme.id {
                        appState.documentThemeId = nil
                    }
                    themeCatalog.deleteCustomTheme(id: theme.id)
                } label: {
                    Label(NSLocalizedString("Delete Theme", comment: ""), systemImage: "trash")
                }
            }
        }
    }

    private var saveThemePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Save Custom Theme", comment: ""))
                .font(.headline)

            Picker("Save Theme Destination", selection: $replacementThemeID) {
                Text("New Theme").tag("")
                ForEach(themeCatalog.customThemes) { Text($0.displayName).tag($0.id) }
            }
            .onChange(of: replacementThemeID) { _, id in
                newThemeName = themeCatalog.theme(for: id)?.name ?? ""
            }
            TextField(NSLocalizedString("Theme Name", comment: ""), text: $newThemeName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)

            HStack {
                Spacer()
                Button(NSLocalizedString("Cancel", comment: "")) {
                    isShowingSaveThemePopover = false
                }
                Button(replacementThemeID.isEmpty ? NSLocalizedString("Save", comment: "") : NSLocalizedString("Overwrite Theme", comment: "")) {
                    let created = themeCatalog.addCustomTheme(
                        name: newThemeName,
                        currentBackgroundHex: appState.backgroundColorHex,
                        currentTextHex: appState.textColorHex, currentHighlightHex: appState.resolvedSearchHighlightHex,
                        isCurrentlyDark: isDocumentDark,
                        typography: appState.currentThemeTypography,
                        replacing: replacementThemeID.isEmpty ? nil : replacementThemeID
                    )
                    appState.applyDocumentTheme(created, isDark: isDocumentDark)
                    isShowingSaveThemePopover = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    // MARK: - 字体

    private var fontSection: some View {
        section(NSLocalizedString("Font", comment: "")) {
            VStack(alignment: .leading, spacing: 8) {
                if showsFontFilterToggle {
                    Toggle(
                        fontFilter == .monospaced
                            ? NSLocalizedString("Monospaced Fonts Only", comment: "")
                            : NSLocalizedString("Chinese Fonts Only", comment: ""),
                        isOn: $filterOnly
                    )
                        .toggleStyle(.checkbox)
                        .onChange(of: filterOnly) { _, newValue in
                            if fontFilter == .monospaced {
                                SettingsStore.shared.documentFontsMonospacedOnly = newValue
                            } else {
                                SettingsStore.shared.documentFontsChineseOnly = newValue
                            }
                        }
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

    private var isBackgroundDefault: Bool {
        let defBg = DocumentThemeCatalog.defaultTheme.backgroundHex(isDark: isDocumentDark)
        return appState.documentThemeId == DocumentThemeCatalog.defaultThemeId
            || appState.backgroundColorHex?.uppercased() == defBg.uppercased()
    }

    private var isTextDefault: Bool {
        let defFg = DocumentThemeCatalog.defaultTheme.textHex(isDark: isDocumentDark)
        return appState.documentThemeId == DocumentThemeCatalog.defaultThemeId
            || appState.textColorHex?.uppercased() == defFg.uppercased()
    }

    private var backgroundStatusText: String {
        if isBackgroundDefault {
            return NSLocalizedString("Default", comment: "")
        }
        if let theme = themeCatalog.theme(for: appState.documentThemeId) {
            return theme.displayName
        }
        return NSLocalizedString("Custom", comment: "")
    }

    private var textStatusText: String {
        if isTextDefault {
            return NSLocalizedString("Default", comment: "")
        }
        if let theme = themeCatalog.theme(for: appState.documentThemeId) {
            return theme.displayName
        }
        return NSLocalizedString("Custom", comment: "")
    }

    private func colorRow(
        color: Binding<Color>,
        statusText: String,
        isDefault: Bool,
        reset: @escaping () -> Void,
        supportsOpacity: Bool = true
    ) -> some View {
        HStack(spacing: 8) {
            ColorPicker(NSLocalizedString("Color", comment: ""), selection: color, supportsOpacity: supportsOpacity)
                .labelsHidden()
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(NSLocalizedString("Default", comment: ""), action: reset)
                .disabled(isDefault)
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

    private var appearanceBinding: Binding<DocumentAppearanceMode> {
        Binding(
            get: { appState.documentAppearance },
            set: { appState.selectDocumentAppearance($0, systemIsDark: colorScheme == .dark) }
        )
    }

    private var backgroundBinding: Binding<Color> {
        Binding(
            get: {
                appState.contentBackgroundColor.map(Color.init(nsColor:))
                    ?? documentSystemColor(.windowBackgroundColor)
            },
            set: { appState.backgroundColorHex = Self.hex(from: $0) }
        )
    }

    private var textColorBinding: Binding<Color> {
        Binding(
            get: {
                appState.documentTextColor.map(Color.init(nsColor:))
                    ?? documentSystemColor(.labelColor)
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

    /// 面板与文档外观不同时，先把动态系统色按文档外观解析，避免透明主题的取色器显示反相颜色。
    private func documentSystemColor(_ color: NSColor) -> Color {
        guard let appearance = appState.documentAppearance.nsAppearance else {
            return Color(nsColor: color)
        }
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return Color(nsColor: resolved)
    }

    private static func hex(from color: Color) -> String? {
        NSColor(color).usingColorSpace(.sRGB)?.toHex()
    }

    // MARK: - 字体列表

    /// 代码内容使用等宽筛选，其余文档使用中文字体筛选。
    private var fontFilter: DocumentFontCatalog.FontFilter {
        appState.prefersMonospacedDocumentFonts ? .monospaced : .chinese
    }

    /// 是否显示字体筛选开关：「只显示中文字体」只对中文系统用户有意义；
    /// 代码内容的等宽筛选始终显示；筛选已经生效（如英文系统打开中文正文）时也保留开关，
    /// 避免出现无法关闭的筛选。
    private var showsFontFilterToggle: Bool {
        fontFilter == .monospaced || DocumentFontCatalog.systemPrefersChinese() || filterOnly
    }

    private var visibleFamilies: [DocumentFontCatalog.Family] {
        guard let catalog else { return [] }
        let families = catalog.families(filter: filterOnly ? fontFilter : .all)
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

/// SwiftUI 分段 Picker 在 macOS 不呈现 Label 图标；原生分段控件显式设置图文，确保亮暗图标可见。
struct DocumentAppearanceSegmentedControl: NSViewRepresentable {
    @Binding var selection: DocumentAppearanceMode

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: DocumentAppearanceMode.allCases.map { _ in "" },
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        control.segmentDistribution = .fill
        control.setAccessibilityIdentifier("documentAppearancePicker")
        control.setAccessibilityLabel(NSLocalizedString("Document Appearance", comment: ""))
        configure(control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        configure(control)
    }

    private func configure(_ control: NSSegmentedControl) {
        for (index, mode) in DocumentAppearanceMode.allCases.enumerated() {
            let title = NSLocalizedString(mode.localizationKey, comment: "")
            control.setLabel(title, forSegment: index)
            let symbolName: String? = switch mode {
            case .system: nil
            case .light: "sun.max"
            case .dark: "moon"
            }
            let image = symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) }
            image?.isTemplate = true
            control.setImage(image, forSegment: index)
        }
        control.selectedSegment = DocumentAppearanceMode.allCases.firstIndex(of: selection) ?? 0
    }

    final class Coordinator: NSObject {
        var parent: DocumentAppearanceSegmentedControl

        init(_ parent: DocumentAppearanceSegmentedControl) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            let modes = DocumentAppearanceMode.allCases
            guard modes.indices.contains(sender.selectedSegment) else { return }
            parent.selection = modes[sender.selectedSegment]
        }
    }
}
