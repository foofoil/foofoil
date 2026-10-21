//
//  TextEditorModeView.swift
//  foofoil
//
//  Created by tolg on 2026/7/10.
//

import SwiftUI

struct TextEditorModeView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var historyManager = HistoryManager.shared
    @State private var shortcutRevision = 0
    @State private var textHeight: CGFloat = 68 // 动态高度，初始为单行行高加上下文档内边距
    @State private var hoveredHistoryID: UUID? = nil
    @State private var isSearchCardHovered = false
    @State private var historyCardLeading: [UUID: CGFloat] = [:]
    @State private var searchCardLeading: CGFloat = 0

    private var historyHintLeading: CGFloat {
        let leading = hoveredHistoryID.flatMap { historyCardLeading[$0] } ?? searchCardLeading
        return leading - 16
    }
    @State private var showRenameAlert = false
    @State private var newTitleText = ""
    @State private var targetRenameConfig: WindowConfig? = nil
    /// 代码 WebKit 预览失败后回退原生视图；换内容时重新尝试。
    @State private var codePreviewFailed = false
    @Environment(\.colorScheme) private var colorScheme

    /// 文本通道（编辑、只读、Markdown）共用的字体：跟随箔的文档字体与字号。
    private var documentTextFont: NSFont {
        appState.documentFont(size: CGFloat(appState.textFontSize))
    }

    private var codePreviewStyle: CodePreviewStyle {
        let isDark: Bool
        if let appearance = DocumentPageInjection.appearance(hex: appState.contentBackgroundHex) {
            isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        } else {
            isDark = colorScheme == .dark
        }
        return CodePreviewStyle(
            fontFamily: DocumentFontCatalog.cssFontFamily(named: appState.documentStylingFontName) ?? DocumentFontCatalog.defaultCodeFontFamily,
            fontSize: appState.textFontSize,
            lineHeight: appState.documentLineHeightMultiple,
            paragraphSpacing: (appState.documentParagraphSpacingMultiple ?? 0) * appState.textFontSize,
            textColor: appState.documentTextColor?.toHex(),
            isDark: isDark,
            showsLineNumbers: appState.showCodeLineNumbers
        )
    }

    var body: some View {
        let _ = shortcutRevision
        GeometryReader { geometry in
            if !appState.agentReadOnly && (geometry.size.width < 100 || geometry.size.height < 100) {
                Color.clear
            } else {
                let isBlank = appState.isBlank
                let showTipsAndHistory = geometry.size.height >= 140 && appState.canOpenRecentHistory

                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        // 文本留白在可滚动文档内；剩余区域为真实窗口背景，用原生手势移动窗口。
                        WindowDragArea()

                        if appState.isMarkdownPreview && appState.isMarkdownDocument && !appState.text.isEmpty {
                            MarkdownTextView(
                                attributedText: appState.renderedMarkdown,
                                calculatedHeight: $textHeight,
                                taskSource: appState.renderedMarkdownSource,
                                scrollRequest: appState.markdownScrollRequest,
                                onVisibleLocationChange: { appState.markdownVisibleLocationDidChange($0, settledLocation: $1) }
                            )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                // 整个滚动视图避开四边缩放热区，滚动条首尾也不会触发角部缩放。
                                .padding(appState.isFullScreen ? 0 : FloatingWindow.resizeHitThickness + 1)
                        } else if appState.agentReadOnly || appState.isArchivePreview || (appState.isReadOnlyTextFile && !appState.isMarkdownDocument) {
                            // 已识别语言的代码优先用 WebKit 语法着色；超限、未识别或失败时回退原生只读视图。
                            if let languageID = appState.webCodePreviewLanguageID, !codePreviewFailed, !appState.agentReadOnly {
                                ReadOnlyCodeView(
                                    text: appState.text,
                                    languageID: languageID,
                                    style: codePreviewStyle,
                                    onFailure: { codePreviewFailed = true }
                                )
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                ReadOnlyTextView(
                                    text: appState.text,
                                    font: documentTextFont,
                                    textColor: appState.documentTextColor,
                                    lineHeightMultiple: appState.documentLineHeightMultiple,
                                    paragraphSpacingMultiple: appState.documentParagraphSpacingMultiple,
                                    codeLineNumbersVisible: appState.codeLanguageID == nil ? nil : appState.showCodeLineNumbers
                                )
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        } else {
                            CustomTextEditor(
                                text: $appState.text,
                                calculatedHeight: $textHeight,
                                fontSize: appState.textFontSize,
                                font: documentTextFont,
                                textColor: appState.documentTextColor,
                                lineHeightMultiple: appState.documentLineHeightMultiple,
                                paragraphSpacingMultiple: appState.documentParagraphSpacingMultiple,
                                shouldMaintainFocus: isBlank
                            )
                                .frame(
                                    maxWidth: .infinity,
                                    maxHeight: appState.text.isEmpty ? nil : .infinity
                                )
                                .frame(height: appState.text.isEmpty ? min(textHeight, geometry.size.height) : nil)
                        }
                    }

                    if isBlank && showTipsAndHistory {
                        BlankStateTipCarousel()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.horizontal, 24)
                            // 不接收鼠标事件，保留窗口背景的拖拽行为和输入焦点。
                            .allowsHitTesting(false)
                    } else {
                        // 剩余区域保持为窗口背景，以支持拖动。
                        Spacer(minLength: 0)
                    }

                    if isBlank && geometry.size.height >= 140 {
                        BlankOpenButtons(appState: appState)
                            .padding(.horizontal, 16)
                            .padding(.bottom, appState.isIncognito ? 16 : 18)
                    }

                    if isBlank && showTipsAndHistory {
                        VStack(alignment: .leading, spacing: 0) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 12) {
                                    let configs = Array(historyManager.historyConfigs.filter({ SettingsStore.shared.appleMusicLibraryEnabled || $0.appleMusicReference == nil }).prefix(30))
                                    ForEach(Array(configs.enumerated()), id: \.element.id) { index, config in
                                        ZStack(alignment: .top) {
                                            HistoryCardView(
                                                config: config,
                                                shortcutText: appState.isCommandKeyPressed && index < 9 ? "⌘\(index + 1)" : nil,
                                                isHovered: hoveredHistoryID == config.id,
                                                action: {
                                                    let isCurrentlyBlank = appState.imageURL == nil && appState.webURL == nil && appState.text.isEmpty
                                                    if isCurrentlyBlank {
                                                        withAnimation(.easeInOut(duration: 0.35)) {
                                                            _ = appState.loadConfig(config)
                                                            appState.startTerminalForExplicitOpen()
                                                        }
                                                    } else {
                                                        appState.loadConfig(config)
                                                            appState.startTerminalForExplicitOpen()
                                                    }
                                                }
                                            )
                                            .contextMenu {
                                                Button {
                                                    historyManager.setFavorite(id: config.id, pinned: !config.historyIsPinned, toast: appState.toast)
                                                } label: {
                                                    Label(NSLocalizedString(config.historyIsPinned ? "Unfavorite History" : "Favorite History", comment: ""), systemImage: config.historyIsPinned ? "bookmark.slash.fill" : "bookmark.fill")
                                                }

                                                Button(action: {
                                                    targetRenameConfig = config
                                                    newTitleText = config.historyMenuDisplayName
                                                    showRenameAlert = true
                                                }) {
                                                    Label(NSLocalizedString("Change Title", comment: ""), systemImage: "pencil")
                                                        .labelStyle(.titleAndIcon)
                                                }

                                                Button(action: {
                                                    historyManager.requestRemoveFromHistory(config)
                                                }) {
                                                    Label(NSLocalizedString("Delete History Record", comment: ""), systemImage: "trash")
                                                        .labelStyle(.titleAndIcon)
                                                }
                                            }

                                            // ⌘ 标题与悬停提示共用缩略图下方的提示带，避免额外留白。
                                            Text(config.historyMenuDisplayName)
                                                .font(.system(size: 9, design: .rounded))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                                .frame(width: 60, height: 22)
                                                .offset(y: 66)
                                                .opacity(appState.isCommandKeyPressed ? 1 : 0)
                                                .animation(.easeInOut(duration: 0.15), value: appState.isCommandKeyPressed)
                                        }
                                        .onGeometryChange(for: CGFloat.self) {
                                            $0.frame(in: .named("blankHistoryViewport")).minX
                                        } action: { historyCardLeading[config.id] = $0 }
                                        .contentShape(Rectangle())
                                        .background {
                                            HoverTrackingView { hovering in
                                                hoveredHistoryID = HistoryItemHover.nextID(
                                                    current: hoveredHistoryID,
                                                    itemID: config.id,
                                                    hovering: hovering
                                                )
                                            }
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        }
                                    }
                                    ZStack(alignment: .top) {
                                        SearchHistoryCard(
                                            shortcutText: appState.isCommandKeyPressed ? KeyboardShortcutStore.shared.shortcut(forID: "history.search")?.displayString : nil,
                                            isHovered: isSearchCardHovered
                                        ) {
                                            HistorySearchWindowController.shared.show()
                                        }
                                        Text(NSLocalizedString("Search History", comment: ""))
                                            .font(.system(size: 9, design: .rounded))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .frame(width: 60, height: 22)
                                            .offset(y: 66)
                                            .opacity(appState.isCommandKeyPressed ? 1 : 0)
                                            .animation(.easeInOut(duration: 0.15), value: appState.isCommandKeyPressed)
                                    }
                                    .onGeometryChange(for: CGFloat.self) {
                                        $0.frame(in: .named("blankHistoryViewport")).minX
                                    } action: { searchCardLeading = $0 }
                                    .contentShape(Rectangle())
                                    .background {
                                        HoverTrackingView { hovering in
                                            isSearchCardHovered = hovering
                                        }
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.bottom, 28)
                            }
                            .frame(height: 88)
                            .coordinateSpace(name: "blankHistoryViewport")
                            .overlay(alignment: .bottom) {
                                BlankFoilHintLayout(sourceLeading: historyHintLeading) {
                                    Group {
                                        if let config = historyManager.historyConfigs.filter({ SettingsStore.shared.appleMusicLibraryEnabled || $0.appleMusicReference == nil }).prefix(30).first(where: { $0.id == hoveredHistoryID }) {
                                            let title = config.historyMenuDisplayName
                                            let url = config.historyWebURLDisplayString
                                            HStack(spacing: 4) {
                                                Image(systemName: config.historyMenuSymbolName)
                                                if let url = url {
                                                    Text("\(title) (\(url))")
                                                } else {
                                                    Text(title)
                                                }
                                            }
                                        } else if isSearchCardHovered {
                                            HStack(spacing: 4) {
                                                Image(systemName: "magnifyingglass")
                                                Text(NSLocalizedString("Search History", comment: ""))
                                            }
                                        } else {
                                            Text(" ")
                                        }
                                    }
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                }
                                .frame(height: 22)
                                .clipped()
                                .padding(.horizontal, 16)
                                .opacity(appState.isCommandKeyPressed ? 0 : 1)
                                .allowsHitTesting(false)
                            }
                            .padding(.bottom, 8)
                        }
                        .background(NonMovableBackground())
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if isBlank && appState.isIncognito {
                        Image(nsImage: IncognitoFoilIcon.image)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: min(96, geometry.size.width * 0.28),
                                   height: min(96, geometry.size.height * 0.28))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Incognito Foil History Hint"))
                            // 大图标覆盖在窗口正中央，不阻挡文本输入、拖放或窗口拖动。
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .keyboardShortcutsDidChange)) { _ in
            shortcutRevision += 1
        }
        .alert(NSLocalizedString("Change Title", comment: ""), isPresented: $showRenameAlert) {
            TextField(NSLocalizedString("Change Title", comment: ""), text: $newTitleText)
            Button(NSLocalizedString("OK", comment: "")) {
                if let config = targetRenameConfig {
                    historyManager.updateHistoryTitle(configId: config.id, newTitle: newTitleText)
                }
            }
            Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {
                targetRenameConfig = nil
            }
        } message: {
            Text("")
        }
        // 暗色/亮色切换时重新生成 markdown 富文本，使颜色跟随系统外观
        .onChange(of: colorScheme) { _, _ in
            if appState.isMarkdownPreview && appState.isMarkdownDocument {
                appState.refreshMarkdownRendering()
            }
        }
        // 自选文字颜色、字体与行距/段距同样写进富文本，改动后立即重渲染预览
        .onChange(of: appState.textColorHex) { _, _ in
            if appState.isMarkdownPreview && appState.isMarkdownDocument {
                appState.refreshMarkdownRendering()
            }
        }
        .onChange(of: appState.documentFontName) { _, _ in
            if appState.isMarkdownPreview && appState.isMarkdownDocument {
                appState.refreshMarkdownRendering()
            }
        }
        .onChange(of: appState.documentLineSpacing) { _, _ in
            if appState.isMarkdownPreview && appState.isMarkdownDocument {
                appState.refreshMarkdownRendering()
            }
        }
        .onChange(of: appState.documentParagraphSpacing) { _, _ in
            if appState.isMarkdownPreview && appState.isMarkdownDocument {
                appState.refreshMarkdownRendering()
            }
        }
        // 回退只针对当前内容：换了文件或文本后重新尝试代码预览。
        .onChange(of: appState.text) { _, _ in
            codePreviewFailed = false
        }
        .onChange(of: appState.textURL) { _, _ in
            codePreviewFailed = false
        }
    }
}

private struct SearchHistoryCard: View {
    let shortcutText: String?
    var isHovered: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(isHovered ? 1 : 0.95))
                Image(systemName: "magnifyingglass").font(.system(size: 24)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let shortcutText {
                    Text(shortcutText).font(.system(size: 10, weight: .bold)).padding(4)
                }
            }.frame(width: 60, height: 60)
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Search History", comment: ""))
    }
}
