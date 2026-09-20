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
    @State private var textHeight: CGFloat = 68 // 动态高度，初始为单行行高加上下文档内边距
    @State private var hoveredHistoryID: UUID? = nil
    @State private var isSearchCardHovered = false
    @State private var showRenameAlert = false
    @State private var newTitleText = ""
    @State private var targetRenameConfig: WindowConfig? = nil
    @Environment(\.colorScheme) private var colorScheme

    /// 文本通道（编辑、只读、Markdown）共用的字体：跟随箔的文档字体与字号。
    private var documentTextFont: NSFont {
        appState.documentFont(size: CGFloat(appState.textFontSize))
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < 100 || geometry.size.height < 100 {
                Color.clear
            } else {
                let isBlank = appState.imageURL == nil && appState.webURL == nil && appState.textURL == nil && appState.text.isEmpty
                let showTipsAndHistory = geometry.size.height >= 140

                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        // 文本留白在可滚动文档内，滚动条贴边；剩余区域为真实窗口背景，用原生手势移动窗口。
                        WindowDragArea()

                        if appState.isMarkdownPreview && appState.isMarkdownDocument && !appState.text.isEmpty {
                            MarkdownTextView(
                                attributedText: appState.renderedMarkdown,
                                calculatedHeight: $textHeight
                            )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if appState.textURL != nil && !appState.isMarkdownDocument {
                            ReadOnlyTextView(
                                text: appState.text,
                                font: documentTextFont,
                                textColor: appState.documentTextColor,
                                lineHeightMultiple: appState.documentLineHeightMultiple,
                                paragraphSpacingMultiple: appState.documentParagraphSpacingMultiple
                            )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

                    if isBlank && showTipsAndHistory {
                        VStack(alignment: .leading, spacing: 0) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 12) {
                                    let configs = Array(historyManager.historyConfigs.prefix(30))
                                    ForEach(Array(configs.enumerated()), id: \.element.id) { index, config in
                                        VStack(spacing: 4) {
                                            HistoryCardView(
                                                config: config,
                                                shortcutText: index < 9 && appState.isCommandKeyPressed ? "⌘\(index + 1)" : nil,
                                                isHovered: hoveredHistoryID == config.id,
                                                action: {
                                                    let isCurrentlyBlank = appState.imageURL == nil && appState.webURL == nil && appState.text.isEmpty
                                                    if isCurrentlyBlank {
                                                        withAnimation(.easeInOut(duration: 0.35)) {
                                                            appState.loadConfig(config)
                                                        }
                                                    } else {
                                                        appState.loadConfig(config)
                                                    }
                                                }
                                            )
                                            .contextMenu {
                                                Button(action: {
                                                    targetRenameConfig = config
                                                    newTitleText = config.historyMenuDisplayName
                                                    showRenameAlert = true
                                                }) {
                                                    Label(NSLocalizedString("Change Title", comment: ""), systemImage: "pencil")
                                                }

                                                Button(action: {
                                                    historyManager.removeFromHistory(config)
                                                }) {
                                                    Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
                                                }
                                            }

                                            // 预留标题高度，按住 ⌘ 时仅切换透明度，避免布局跳动；复用现有底部 padding 的空间。
                                            Text(config.historyMenuDisplayName)
                                                .font(.system(size: 9, design: .rounded))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                                .frame(width: 60)
                                                .opacity(appState.isCommandKeyPressed ? 1 : 0)
                                                .animation(.easeInOut(duration: 0.15), value: appState.isCommandKeyPressed)
                                        }
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
                                    VStack(spacing: 4) {
                                        SearchHistoryCard(
                                            shortcutText: appState.isCommandKeyPressed ? "⌘P" : nil,
                                            isHovered: isSearchCardHovered
                                        ) {
                                            HistorySearchWindowController.shared.show()
                                        }
                                        Text(NSLocalizedString("Search History", comment: ""))
                                            .font(.system(size: 9, design: .rounded))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .frame(width: 60)
                                            .opacity(appState.isCommandKeyPressed ? 1 : 0)
                                            .animation(.easeInOut(duration: 0.15), value: appState.isCommandKeyPressed)
                                    }
                                    .contentShape(Rectangle())
                                    .background {
                                        HoverTrackingView { hovering in
                                            isSearchCardHovered = hovering
                                        }
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                                .padding(.bottom, 8)
                            }

                            Group {
                                if let config = historyManager.historyConfigs.prefix(30).first(where: { $0.id == hoveredHistoryID }) {
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
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                            .frame(height: 14)
                        }
                        .background(NonMovableBackground())
                    }
                }
            }
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
