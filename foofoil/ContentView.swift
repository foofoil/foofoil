//
//  ContentView.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//

import SwiftUI
import AppKit
import Combine
import FoofoilExtensionKit

public struct ContentView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) { self.appState = appState }

    public var body: some View {
        Group {
            if let session = appState.archiveSession {
                ArchiveFoilView(windowState: appState, session: session)
            } else {
                FoilContentView(appState: appState, windowState: appState)
            }
        }
        // 包内切换文件会重建正文；导航宿主保持独立身份，避免切换后丢失键盘焦点。
        .overlay {
            FullScreenNavigatorOverlay(appState: appState)
                .opacity(appState.isCapturingContentImage ? 0 : 1)
        }
    }
}

/// 包内外共用完整的正文、背景、留白和交互；窗口与导航始终归实际箔片。
struct FoilContentView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var windowState: AppState
    var archive: ArchiveSession? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var isResizingWindowWithPinch = false
    @State private var pdfPageIndicator: String?
    @State private var pdfPageIndicatorDismissTask: DispatchWorkItem?
    @State private var flashOpacity: Double = 0.0


    public var body: some View {
        // 网页和图片都支持仅隐藏视觉边框；网页切换边框不应改变窗口的缩放规则。
        // 仅允许可切换边框的类型进入无边框模式；固定边框类型始终保留代码箔式的边框。
        let shouldHideBorder = windowState.isFullScreen
            || ((appState.isCamera || appState.imageURL != nil || appState.webURL != nil || appState.isAudioDocument) && appState.supportsBorderToggle && !appState.showBorder)
        // 网页即使同时保留了截图缓存，也不能套用图片无边框模式的最小尺寸规则。
        let isImageMode = appState.usesImagePresentation
        let usesCompactMinimumSize = isImageMode && !appState.effectiveShowBorder
        let minimumLength: CGFloat = usesCompactMinimumSize ? 80 : 150
        // 音视频窗口再抬高最小宽度，保证底部播放条单行能放下。
        let minimumWidth = appState.isExternalMediaDocument
            ? max(minimumLength, MediaPlaybackBarMetrics.minimumWindowWidth)
            : (appState.isPPTXDocument ? max(minimumLength, PPTXModeView.minimumWindowWidth) : minimumLength)
        // PDF 显示边框时，四周保留 12pt 的边框区域。
        let isMarkdownPreview = appState.isMarkdownPreview && appState.isMarkdownDocument
        // Markdown 也按代码箔的 4pt 边框留白；不再满铺窗口。
        let contentPadding: CGFloat = isMarkdownPreview ? 4 : (appState.isPDFDocument && appState.effectiveShowBorder ? 12 : (shouldHideBorder ? 0 : 4))
        // 内容背景色：只作用于文档箔的内容，窗口毛玻璃不再随之着色。
        let contentBackgroundColor = appState.contentBackgroundColor
        // 与毛玻璃圆角同心的内缩圆角：内容越贴边，圆角越接近窗口的 12pt 圆角。
        let contentBackgroundCornerRadius: CGFloat = shouldHideBorder ? 0 : max(0, 12 - contentPadding)
        // 嵌平“始终显示”时被导航面板挤占的内容宽度；其余情况为 0。
        let navigatorContentInset = windowState.fullScreenNavigatorContentInset

        ZStack {
            // 毛玻璃背景 (玻璃拟态效果)
            if windowState.isFullScreen {
                // 全屏统一使用无圆角的整屏背景，不继承窗口态的有/无边框外观。
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
            } else if !shouldHideBorder {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                    .cornerRadius(12)
                    // 毛玻璃背景是可拖拽区域；内容层上的控件仍优先处理事件。
                    .gesture(WindowDragGesture())
            } else if appState.webURL != nil {
                // 网页视图关闭了 WebKit 自身背景；无边框时仍保留与有边框模式一致的毛玻璃背景，避免透明区域直接露出桌面。
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                    .gesture(WindowDragGesture())
            }

            // 内容区域
            Group {
                if let archive, archive.preview == nil || appState.isFileOpenFeedback {
                    ArchiveContentView(session: archive)
                } else if appState.isFileOpenFeedback {
                    FileOpenFeedbackView(failures: appState.fileOpenFeedback) {
                        NotificationCenter.default.post(
                            name: .shouldCloseWindow,
                            object: nil,
                            userInfo: ["id": appState.id]
                        )
                    }
                } else if appState.isLoading || (appState.isArchivePreview && !appState.hasOpenedContent) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.2)
                        .transition(.opacity)
                } else if appState.appleMusicReference != nil {
                    AppleMusicModeView(appState: appState, shouldHideBorder: shouldHideBorder)
                } else if appState.extensionSession != nil {
                    ExtensionPresentationView(appState: appState, shouldHideBorder: shouldHideBorder)
                        .transition(.opacity)
                } else if appState.isCamera, let camera = appState.cameraController {
                    CameraModeView(appState: appState, controller: camera, shouldHideBorder: shouldHideBorder)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let webURL = appState.webURL {
                    // 网页支持内容缩放；调整窗口大小只改变可视区域。
                    WebContainerView(url: webURL, zoom: appState.webZoom, appState: appState, onTitleChange: { title in
                        appState.applyWebDocumentTitle(title)
                    }, onScreenshotTaken: { image in
                        appState.saveWebScreenshot(image)
                    }, shouldHideBorder: shouldHideBorder)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else if let url = appState.imageURL, appState.isQuickLookDocument {
                    if url.pathExtension.lowercased() == "pptx" {
                        PPTXModeView(appState: appState, url: url)
                    } else {
                        QuickLookModeView(url: url, shouldHideBorder: shouldHideBorder)
                            .clipShape(RoundedRectangle(cornerRadius: shouldHideBorder ? 0 : 8, style: .continuous))
                    }
                } else if let videoURL = appState.imageURL, appState.isVideoDocument {
                    VideoModeView(appState: appState, url: videoURL, shouldHideBorder: shouldHideBorder)
                        .transition(.opacity)
                } else if let audioURL = appState.imageURL, appState.isAudioDocument {
                    AudioModeView(appState: appState, url: audioURL, shouldHideBorder: shouldHideBorder)
                        .transition(.opacity)
                } else if appState.isAudioDocument, appState.fileList?.currentItem != nil {
                    // 扩展音频会话打开失败或授权失效时不再落入空文本模式，保持可辨识的箔片外观。
                    ContentUnavailableView(
                        NSLocalizedString("Audio Content Unavailable", comment: ""),
                        systemImage: "music.note",
                        description: Text(NSLocalizedString("Audio Content Unavailable Message", comment: ""))
                    )
                    .transition(.opacity)
                } else if let pdfURL = appState.imageURL, appState.isPDFDocument {
                    PDFModeView(appState: appState, url: pdfURL)
                        .transition(.opacity)
                } else if let imageURL = appState.imageURL, let nsImage = appState.loadImage(from: imageURL) {
                    ImageModeView(appState: appState, nsImage: nsImage, shouldHideBorder: shouldHideBorder)
                        .id(appState.fileList?.currentID ?? imageURL.path)
                        .transition(.opacity)
                } else if appState.isCSVDocument {
                    CSVTableView(content: appState.text, fontSize: appState.textFontSize)
                        .transition(.opacity)
                } else {
                    // 文字模式
                    TextEditorModeView(appState: appState)
                        .transition(.opacity)
                }
            }
            // 文档内容背景：只铺在内容之下，窗口毛玻璃与窗口边缘的留白不随之变色。
            .background {
                if let contentBackgroundColor {
                    Color(contentBackgroundColor)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: contentBackgroundCornerRadius,
                                style: .continuous
                            )
                        )
                }
            }
            .background(FoilCaptureArea(id: appState.id))
            .padding(contentPadding)
            // 嵌平“始终显示”时侧边栏以分栏形式挤占内容空间而不是盖在内容上；
            // 悬停模式侧边栏覆盖内容，内容保持原位。拖拽调宽时跟随指针即时变化不动画。
            .padding(windowState.navigatorPanelSide == .left ? .leading : .trailing, navigatorContentInset)
            .animation(
                windowState.isAdjustingNavigatorPanelWidth
                    ? nil
                    : .easeInOut(duration: 0.25),
                value: navigatorContentInset
            )
            .animation(
                appState.fileList?.kind == .image ? ImageListSlideshow.transitionAnimation : nil,
                value: appState.fileList?.currentID
            )

            // 截图闪白覆盖层
            Color.white
                .cornerRadius(shouldHideBorder ? 0 : 12)
                .opacity(flashOpacity)
                .allowsHitTesting(false)

        }
        .frame(minWidth: minimumWidth, minHeight: minimumLength)
        // Finder 文件由 FloatingWindow 直接读取粘贴板，确保多选批次不会被 SwiftUI 拆丢。
        // 增加高精细度细微边框，且拖拽时显示蓝色高亮边框
        .overlay(
            RoundedRectangle(cornerRadius: shouldHideBorder ? 0 : 12)
                .stroke(windowState.isFileDropTargeted ? Color.blue.opacity(0.8) : (shouldHideBorder ? Color.clear : Color.white.opacity(0.15)), lineWidth: windowState.isFileDropTargeted ? 3 : 1)
        )
        .overlay(alignment: .bottom) {
            if let pdfPageIndicator, !windowState.isCapturingContentImage {
                Text(pdfPageIndicator)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, shouldHideBorder ? 12 : 20)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: pdfPageIndicator)
        // 系统明暗切换后，把与目标主题明显不符的自定义背景色、文字颜色换成同色相的深浅版本。
        .onChange(of: colorScheme) { _, newScheme in
            appState.adaptDocumentColorsToAppearanceChange(toDarkAppearance: newScheme == .dark)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("flashWindow_\(windowState.id.uuidString)"))) { _ in
            // 瞬间变白（0.85 不透明度）
            flashOpacity = 0.85
            // 渐变褪去
            withAnimation(.easeOut(duration: 0.4)) {
                flashOpacity = 0.0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfPageDidChange)) { notification in
            guard let targetId = notification.userInfo?["id"] as? UUID,
                  targetId == appState.id,
                  let currentPage = notification.userInfo?["currentPage"] as? Int,
                  let pageCount = notification.userInfo?["pageCount"] as? Int else { return }

            pdfPageIndicator = "\(currentPage)/\(pageCount)"
            pdfPageIndicatorDismissTask?.cancel()
            let dismissTask = DispatchWorkItem {
                withAnimation {
                    pdfPageIndicator = nil
                }
            }
            pdfPageIndicatorDismissTask = dismissTask
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: dismissTask)
        }
        // 图片模式下：有边框时鼠标双击作用改为和cmd.一样，无边框时双击作用改为和cmd=一样（放大）
        .onTapGesture(count: 2) {
            if appState.usesImagePresentation {
                if appState.effectiveShowBorder {
                    NotificationCenter.default.post(
                        name: .shouldFitImageToWindowWidth,
                        object: nil,
                        userInfo: ["id": appState.id]
                    )
                } else {
                    NotificationCenter.default.post(
                        name: .shouldZoomIn,
                        object: nil,
                        userInfo: ["id": appState.id]
                    )
                }
            }
        }
        // 图片模式继续由 ImageModeView 自己处理捏合缩放；音视频及其余模式仅缩放窗口，不改变内容字号或网页倍率。
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    guard !appState.isCamera, appState.imageURL == nil || appState.isExternalMediaDocument || appState.isQuickLookDocument || appState.webURL != nil else { return }

                    if !isResizingWindowWithPinch {
                        isResizingWindowWithPinch = true
                    }
                    NotificationCenter.default.post(
                        name: .shouldResizeWindowWithPinch,
                        object: nil,
                        userInfo: ["id": windowState.id, "magnification": value]
                    )
                }
                .onEnded { _ in
                    guard (appState.imageURL == nil || appState.isExternalMediaDocument || appState.isQuickLookDocument || appState.webURL != nil), isResizingWindowWithPinch else { return }

                    NotificationCenter.default.post(
                        name: .shouldEndWindowPinchResize,
                        object: nil,
                        userInfo: ["id": windowState.id]
                    )
                    isResizingWindowWithPinch = false
                }
        )
        .contextMenu {
            Toggle(isOn: $windowState.isPinned) {
                Label(NSLocalizedString("Toggle Pin (ContextMenu)", comment: ""), systemImage: "pin")
            }
                .configuredKeyboardShortcut("view.togglePin")

            if !windowState.isFullScreen && appState.supportsBorderToggle {
                Toggle(isOn: $appState.showBorder) {
                    Label(NSLocalizedString("Border (ContextMenu)", comment: ""), systemImage: "rectangle")
                }
                    .configuredKeyboardShortcut("view.toggleBorder")
            }

            if appState.canToggleImageListSlideshow {
                Toggle(isOn: Binding(
                    get: { appState.fileList?.isSlideshowEnabled == true },
                    set: { appState.setImageListSlideshowEnabled($0) }
                )) {
                    Label(NSLocalizedString("Slideshow (ContextMenu)", comment: ""), systemImage: "play.rectangle")
                }
                .configuredKeyboardShortcut("view.slideshow")
            }

            Button {
                (NSApp.delegate as? AppDelegate)?.saveContentImageAction()
            } label: {
                Label("Save Content Image", systemImage: "photo")
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(!appState.canSaveContentImage)
            Button {
                (NSApp.delegate as? AppDelegate)?.saveAsAction()
            } label: {
                Label("Save As...", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(windowState.selectedArchiveSession.map { !$0.canExport } ?? (appState.contentSavePayload == nil))

            if appState.packageContentsURL != nil {
                Button {
                    (NSApp.delegate as? AppDelegate)?.openPackageContentsAction()
                } label: {
                    Label("Open Package Contents", systemImage: "archivebox")
                }
            }

            if appState.isVideoDocument {
                SubtitleVisibilityToggle(controller: appState.subtitles)
                Button { appState.subtitles.pickFile() } label: {
                    Label("Load Subtitle File", systemImage: "captions.bubble")
                }
            }

            if appState.usesImagePresentation {
                // 视频/音频没有“拷贝图片”能力
                if !appState.isExternalMediaDocument {
                    Button(action: {
                        if appState.isCamera {
                            appState.cameraController?.capture { image in
                                guard let image else { return }
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.writeObjects([image])
                            }
                        } else {
                            appState.copyCurrentImageToPasteboard()
                        }
                    }) {
                        Label(NSLocalizedString("Copy Image", comment: ""), systemImage: "photo.on.rectangle")
                    }
                    .keyboardShortcut("c", modifiers: [.command])
                }

                if appState.isSVG {
                    Button(action: {
                        appState.showColorPanel()
                    }) {
                        Label(NSLocalizedString("Select Color", comment: ""), systemImage: "eyedropper")
                    }
                    .configuredKeyboardShortcut("view.selectColor")
                }

                if appState.effectiveShowBorder {
                    Button(action: {
                        NotificationCenter.default.post(
                            name: .shouldFitWindowToImage,
                            object: nil,
                            userInfo: ["id": appState.id]
                        )
                    }) {
                        Label(NSLocalizedString("Fit Window to Image", comment: ""), systemImage: "rectangle.inset.filled")
                    }
                    .configuredKeyboardShortcut("view.fitWindowToImage")

                    Button(action: {
                        NotificationCenter.default.post(
                            name: .shouldFitImageToWindowWidth,
                            object: nil,
                            userInfo: ["id": appState.id]
                        )
                    }) {
                        Label(NSLocalizedString("Fit Image to Window Width", comment: ""), systemImage: "arrow.left.and.right")
                    }
                    .configuredKeyboardShortcut("view.fitImageToWindowWidth")
                }
            }

            if appState.isAudioDocument {
                Button(action: {
                    appState.copyAudioCoverToPasteboard()
                }) {
                    Label(NSLocalizedString("Copy Cover", comment: ""), systemImage: "photo.on.rectangle")
                }
                .disabled(appState.audioCoverImage == nil)
                .keyboardShortcut("c", modifiers: [.command])
            }

            if appState.isCamera {
                if let camera = appState.cameraController { CameraDeviceContextMenu(controller: camera) }
            } else if !appState.isVideoDocument {
                // 提取文字：仅光栅图片箔可用；图中无字时也禁用，检测未完成前保持禁用。
                Button(action: {
                    (NSApplication.shared.delegate as? AppDelegate)?.extractTextFromImage(from: appState)
                }) {
                    Label(NSLocalizedString("Extract Text", comment: ""), systemImage: "text.viewfinder")
                }
                .disabled(!appState.canExtractImageText)
                .configuredKeyboardShortcut("edit.extractText")

                // 提取主体：还要等图片载入后 Vision 给出结论，检测期间显示但禁用。
                Button(action: {
                    (NSApplication.shared.delegate as? AppDelegate)?.extractImageSubject(from: appState)
                }) {
                    Label(NSLocalizedString("Extract Image Subject", comment: ""), systemImage: "person.and.background.dotted")
                }
                .disabled(!appState.canExtractImageSubject)
                .configuredKeyboardShortcut("edit.extractImageSubject")
            }

            Divider()

            Button(action: {
                windowState.resetContent()
            }) {
                Label(NSLocalizedString("Reset (ContextMenu)", comment: ""), systemImage: "arrow.counterclockwise")
            }
            .configuredKeyboardShortcut("file.reset")

            Button(action: {
                NotificationCenter.default.post(
                    name: .shouldCloseWindow,
                    object: nil,
                    userInfo: ["id": windowState.id]
                )
            }) {
                Label(NSLocalizedString("Close (ContextMenu)", comment: ""), systemImage: "xmark.circle")
            }
            .keyboardShortcut("w", modifiers: [.command])

            Divider()

            // 与系统 ⌘H 一致：隐藏整个应用，交给 AppDelegate 的 hide 生命周期收起箔片。
            Button(action: {
                NSApp.hide(nil)
            }) {
                Label(NSLocalizedString("Hide", comment: ""), systemImage: "eye.slash")
            }
            .keyboardShortcut("h", modifiers: [.command])
        }
    }

}

private struct FullScreenNavigatorOverlay: View {
    @ObservedObject var appState: AppState
    @ObservedObject var hover: NavigatorHoverState

    init(appState: AppState) {
        self.appState = appState
        self.hover = appState.navigatorHover
    }

    var body: some View {
        // 固定覆盖层容器，只让面板自身从对应侧边滑入，避免按整个窗口宽度移动。
        ZStack(alignment: appState.navigatorPanelSide == .left ? .leading : .trailing) {
            if isVisible {
                FullScreenNavigatorHost(appState: appState)
                    .frame(width: CGFloat(appState.navigatorPanelWidth))
                    .transition(.move(edge: appState.navigatorPanelSide == .left ? .leading : .trailing))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: appState.navigatorPanelSide == .left ? .leading : .trailing)
        .clipped()
        .animation(.easeInOut(duration: 0.25), value: isVisible)
        .zIndex(20)
    }

    private var isVisible: Bool {
        appState.isFullScreenNavigatorVisible
    }
}
