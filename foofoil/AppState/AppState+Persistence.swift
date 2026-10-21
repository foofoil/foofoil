//  AppState+Persistence.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//


import Foundation
import Combine
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO
import SwiftUI
import FoofoilExtensionKit


extension AppState {
        public func saveState() {
            guard !isArchivePreview, archiveSession?.hasTemporarySource != true, !isFileOpenFeedback, !isBatchUpdating, !isAdjustingDocumentStyling else { return }
            persistManagedTextIfNeeded()
            let unused = ownedBodyPaths.subtracting(cachedContentPaths)
            if !isLoading { ContentCache.shared.retire(unused); ownedBodyPaths.subtract(unused) }
            if let delegate = NSApplication.shared.delegate as? AppDelegate {
                ContentCache.shared.protect(Set(delegate.windowControllers.map { $0.appState.id }).union([id]),
                    paths: Set(delegate.windowControllers.flatMap { $0.appState.cachedContentPaths }).union(cachedContentPaths))
            }
            guard !isIncognito, !HistoryRepository.shared.wasDeleted(id) else { return }
            if hasOpenedContent || appleMusicReference != nil {
                if !fileOpenFeedback.isEmpty { fileOpenFeedback = [] }
                closesEmptyWindowAfterFileOpenFailure = false
            }
            // 补齐仍能可靠识别的原文件来源；托管缓存永远不能充当原路径。
            if sourceFingerprint == nil, fileList == nil, appleMusicReference == nil,
               let source = FoilInformation.sourceURL(for: toConfig()) {
                sourceFingerprint = Self.localSourceFingerprint(for: source)
            }
            let config = toConfig()
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if terminalConfiguration != nil || archiveSession != nil || appleMusicReference != nil || isCamera || imageURL != nil || webURL != nil || textURL != nil || extensionSession != nil || !trimmedText.isEmpty {
                HistoryManager.shared.addToHistory(config)
            }
        }

        @discardableResult
        public func loadConfig(_ inputConfig: WindowConfig, isRefreshing: Bool = false, preservesIdentity: Bool = false) -> Bool {
            if let path = inputConfig.textPath, Self.isManagedCacheURL(URL(fileURLWithPath: path)),
               ContentCache.shared.hasLease(for: path) { ContentCache.shared.flushBodyWrites() }
            let historyIsPinned = HistoryRepository.shared.config(id: inputConfig.id)?.historyIsPinned ?? inputConfig.historyIsPinned
            let resolution = inputConfig.resolvingFileReferences(removeMissingItems: !isIncognito && !isRefreshing && SettingsStore.shared.automaticallyRemoveMissingHistory && !historyIsPinned)
            let config = resolution.config
            if resolution.missing, !isIncognito, SettingsStore.shared.automaticallyRemoveMissingHistory, !isRefreshing {
                HistoryManager.shared.removeFromHistory(inputConfig, preservingLegacyBody: true)
                if let failure = config.historyRestoreFileFailure() { reportFileOpenFeedback([failure]) }
                return false
            }
            // 先确认正文可读，再覆盖窗口状态；失败不继承旧历史的无边框设置或留下占位窗口。
            if let failure = config.historyRestoreFileFailure() {
                reportFileOpenFeedback([failure])
                return false
            }
            stopVideoAccess()
            if !isRefreshing { relinquishAgentControl() }
            archiveSession?.close()
            archiveSession = nil
            appleMusicItem = nil
            // 即使连续载入同一条历史，也必须使上一轮异步恢复失效。
            currentMediaRouteGeneration &+= 1
            isLoading = false
            isBatchUpdating = true
            defer {
                isBatchUpdating = false
                saveState()
                if let url = imageURL, !Self.isManagedCacheURL(url), !isIncognito,
                   !HistoryRepository.shared.wasDeleted(id) {
                    ContentIndexCoordinator.shared.schedule(config: toConfig(), force: true)
                }
                updateRenderedMarkdown()
            }

            // 普通恢复沿用历史 UUID；无痕副本保留自己的会话身份。
            if !preservesIdentity { self.id = config.id }
            self.sourceFingerprint = config.sourceFingerprint
            self.agentReadOnly = config.readOnlyPresentation
            self.isPinned = config.isPinned
            self.opacity = config.opacity
            self.originalImageName = config.sourceFingerprint == SupportedContentOverview.sourceFingerprint
                ? NSLocalizedString("Supported Content Overview", comment: "") + ".md"
                : config.originalImageName
            self.customTitle = config.customTitle
            terminalSession?.stop()
            terminalConfiguration = config.terminalConfiguration
            terminalSession = config.terminalConfiguration.map { TerminalSession(configuration: $0, previousOutput: isIncognito ? nil : config.terminalScrollback) }
            configureTerminalSnapshotSaving()
            self.imageSource = config.imageSource
            self.showBorder = config.showBorder
            self.showCodeLineNumbers = config.showCodeLineNumbers ?? true
            self.imageScale = Self.clampImageScale(config.imageScale)
            self.textFontSize = Self.clampTextFontSize(config.textFontSize)
            self.webZoom = Self.clampWebZoom(config.webZoom)
            self.documentZoom = Self.clampDocumentZoom(config.documentZoom)
            self.isMarkdownPreview = config.isMarkdownPreview
            self.windowFrame = config.windowFrame
            self.createdAt = config.createdAt
            self.svgColor = config.svgColor
            self.backgroundColorHex = config.backgroundColorHex
            self.textColorHex = config.textColorHex
            self.documentThemeId = config.documentThemeId
            self.documentFontName = config.documentFontName
            self.documentLineSpacing = config.documentLineSpacing
            self.documentParagraphSpacing = config.documentParagraphSpacing
            self.mediaPlaybackMode = config.mediaPlaybackMode
            self.extensionStateReference = config.extensionStateReference
            self.extensionDocumentScrollFile = config.documentScrollFile
            self.extensionDocumentScrollFraction = Self.clampScrollFraction(config.documentScrollFraction)
            self.navigatorPanelSide = config.navigatorPanelSide
            self.navigatorPanelVisibilityMode = config.navigatorPanelVisibilityMode
            self.navigatorPanelWidth = NavigatorPanelMetrics.clampWidth(config.navigatorPanelWidth)
            self.fileList = nil
            self.fileListRevision = 0
            self.stopImageListSlideshow()
            self.builtInNavigatorContributions = []
            self.builtInNavigatorActionHandler = nil
            self.isNavigatorPanelExplicitlyVisible = false
            self.activeNavigatorContributionID = nil
            self.expandedNavigatorItemIDs = []
            subtitles.restore(config.subtitleAssociations)
            restoreFileList(from: config)
            restoreExtensionSession(from: config)
            restoreCustomCover(from: config)

            // 载入历史记录时，一律尝试通知窗口控制器恢复当初保存的窗口位置与尺寸
            if let frameString = config.windowFrame {
                NotificationCenter.default.post(
                    name: .shouldRestoreFrame,
                    object: nil,
                    userInfo: ["frame": frameString, "id": id]
                )
            }

            if let path = config.imagePath, config.contentKind != .archive {
                let url = URL(fileURLWithPath: path)
                // 通过普通书签定位媒体文件，兼顾文件移动。
                if !Self.isManagedCacheURL(url) {
                    // 加载新配置前先释放旧的媒体授权
                    stopVideoAccess()
                    if let restored = Self.restoreVideoAccess(config: config, fallbackURL: url) {
                        self.accessingVideoURL = restored.accessedURL
                        self.videoBookmarkData = restored.bookmark
                        self.quickLookSourceURL = config.contentKind == .quickLook ? restored.url : nil
                        self.imageURL = restored.url
                    } else {
                        self.imageURL = url
                        self.videoBookmarkData = config.videoBookmark
                        reportFileOpenFeedback([.init(url: url, reason: .unreadable)])
                    }
                } else if FileManager.default.fileExists(atPath: url.path) {
                    self.imageURL = url
                } else {
                    self.imageURL = nil
                }
            } else {
                self.imageURL = nil
            }

            // 重开历史时直接采用持久化的 OCR 与主体结论，不再重跑 Vision。
            if !isRefreshing { restoreImageDerivedContent(from: config) }

            stopCamera()
            if config.isCamera { openCamera() }
            if let webStr = config.webURLString, let url = URL(string: webStr) {
                self.webURL = url
                if url.isFileURL { retainFileAccess(to: url) }
            } else {
                self.webURL = nil
            }

            if let actualWebStr = config.actualWebURLString, let url = URL(string: actualWebStr) {
                self.actualWebURL = url
            } else {
                self.actualWebURL = nil
            }
            if config.sourceFingerprint == KeyboardShortcutsOverview.sourceFingerprint {
                self.textURL = nil
                self.text = KeyboardShortcutsOverview.markdown()
            } else if config.sourceFingerprint == SupportedContentOverview.sourceFingerprint {
                self.textURL = nil
                self.text = SupportedContentOverview.markdown()
            } else if let path = config.textPath {
                let url = URL(fileURLWithPath: path)
                retainFileAccess(to: url)
                if FileManager.default.fileExists(atPath: url.path) {
                    self.textURL = url
                    do {
                        self.text = try Self.readTextContent(from: url)
                    } catch {
                        self.text = ""
                        reportFileOpenFeedback([.init(url: url, reason: .unreadable)])
                    }
                } else {
                    self.textURL = url
                    self.text = ""
                    reportFileOpenFeedback([.init(url: url, reason: .unreadable)])
                }
            } else {
                self.textURL = nil
                self.text = config.text
            }
            self.appleMusicReference = config.appleMusicReference
            if let source = config.archiveSource, !source.volumes.isEmpty { restoreArchive(source) }
            return true
        }

        /// 恢复图片箔的派生内容缓存（OCR 文字与主体抠图）以及菜单可用性判断所需的"已分析"标记。
        /// 结论存在就让检测直接跳过；主体结论存在但抠图缓存丢失时，保留结论并允许检测重新生成。
        func restoreImageDerivedContent(from config: WindowConfig) {
            if let path = config.imagePath, !Self.isManagedCacheURL(URL(fileURLWithPath: path)) { return }
            imageOCRText = config.imageOCRText
            if let text = config.imageOCRText, imageURL != nil {
                hasExtractableImageText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                imageTextDetectedURL = imageURL
            } else {
                hasExtractableImageText = false
                imageTextDetectedURL = nil
            }

            switch config.imageHasSubject {
            case true?:
                hasExtractableImageSubject = true
                if let path = config.imageSubjectPath, FileManager.default.fileExists(atPath: path) {
                    imageSubjectCutoutURL = URL(fileURLWithPath: path)
                    imageSubjectDetectedURL = imageURL
                } else {
                    imageSubjectCutoutURL = nil
                    imageSubjectDetectedURL = nil
                }
            case false?:
                hasExtractableImageSubject = false
                imageSubjectCutoutURL = nil
                imageSubjectDetectedURL = imageURL
            case nil:
                hasExtractableImageSubject = false
                imageSubjectCutoutURL = nil
                imageSubjectDetectedURL = nil
            }
        }

        public func toConfig() -> WindowConfig {
            if let archiveSession {
                return WindowConfig(id: id, imagePath: archiveSession.source.primaryURL.path,
                    originalImageName: archiveSession.source.name,
                    isPinned: isPinned, opacity: opacity, windowFrame: windowFrame,
                    createdAt: createdAt, contentKind: .archive, sourceFingerprint: sourceFingerprint,
                    customTitle: customTitle, videoBookmark: archiveSession.source.volumes.first?.bookmark,
                    navigatorPanelSide: navigatorPanelSide, navigatorPanelVisibilityMode: navigatorPanelVisibilityMode,
                    navigatorPanelWidth: navigatorPanelWidth, archiveSource: archiveSession.source)
            }
            // 视频扩展也记录原文件来源，供历史存活检查及重启后授权恢复使用。
            let videoResource = isVideoDocument ? extensionSession.flatMap { ExtensionPlaybackSupport.authorizedResource(in: $0, fileList: fileList) } : nil
            return WindowConfig(
                id: id,
                imagePath: videoResource?.url.path ?? imageURL?.path,
                isCamera: isCamera,
                webURLString: webURL?.absoluteString,
                actualWebURLString: actualWebURL?.absoluteString,
                originalImageName: originalImageName,
                imageSource: imageSource,
                text: agentReadOnly ? "" : text,
                isPinned: isPinned,
                opacity: opacity,
                windowFrame: windowFrame,
                showBorder: showBorder,
                imageScale: imageScale,
                textFontSize: textFontSize,
                isMarkdownPreview: isMarkdownPreview,
                createdAt: createdAt,
                svgColor: svgColor,
                backgroundColorHex: backgroundColorHex,
                textColorHex: textColorHex,
                documentFontName: documentFontName,
                documentLineSpacing: documentLineSpacing,
                documentParagraphSpacing: documentParagraphSpacing,
                documentThemeId: documentThemeId,
                textPath: textURL?.path,
                contentKind: terminalConfiguration != nil ? .terminal : appleMusicReference != nil ? .audio : isVideoDocument ? .video : isQuickLookDocument ? .quickLook : HistoryContentKind.infer(from: WindowConfig(
                    id: id,
                    imagePath: imageURL?.path,
                    isCamera: isCamera,
                    webURLString: webURL?.absoluteString,
                    originalImageName: originalImageName,
                    text: text,
                    isMarkdownPreview: isMarkdownPreview,
                    textPath: textURL?.path,
                    extensionID: extensionSession?.extensionID,
                    fileList: fileList?.items.isEmpty == false ? fileList : nil
                )),
                sourceFingerprint: sourceFingerprint,
                customTitle: customTitle,
                imageOCRText: imageOCRText,
                imageHasSubject: imageSubjectDetectedURL != nil ? hasExtractableImageSubject : nil,
                imageSubjectPath: imageSubjectCutoutURL?.path,
                webZoom: webZoom,
                documentZoom: documentZoom,
                mediaPlaybackMode: mediaPlaybackMode,
                subtitleAssociations: subtitles.history.isEmpty ? nil : subtitles.history,
                videoBookmark: videoResource?.securityScopedBookmark ?? videoBookmarkData,
                customCoverPath: customCoverURL?.path,
                extensionID: extensionSession?.extensionID,
                extensionStateReference: extensionStateReference,
                navigatorPanelSide: navigatorPanelSide,
                navigatorPanelVisibilityMode: navigatorPanelVisibilityMode,
                navigatorPanelWidth: navigatorPanelWidth,
                fileList: fileList?.items.isEmpty == false ? fileList : nil,
                documentScrollFile: extensionDocumentScrollFile,
                documentScrollFraction: extensionDocumentScrollFraction,
                appleMusicReference: appleMusicReference,
                showCodeLineNumbers: showCodeLineNumbers,
                readOnlyPresentation: agentReadOnly,
                terminalConfiguration: terminalConfiguration,
                terminalScrollback: isIncognito ? nil : terminalSession?.outputSnapshot
            )
        }

        /// 文档滚动位置回传：与章节文件名成对记录，去抖后落盘，避免滚动期间频繁写历史。
        func noteExtensionDocumentScroll(file: String, fraction: Double) {
            guard isExtensionDocument,
                  !file.isEmpty,
                  let clamped = Self.clampScrollFraction(fraction) else { return }
            if extensionDocumentScrollFile == file,
               let current = extensionDocumentScrollFraction,
               abs(current - clamped) < 0.005 { return }
            extensionDocumentScrollFile = file
            extensionDocumentScrollFraction = clamped
            scheduleDocumentScrollSave()
        }

        /// 滚动停止约一秒后保存；其它路径的 saveState 直接读取当前值，不会丢最后一次滚动。
        func scheduleDocumentScrollSave() {
            documentScrollSaveTask?.cancel()
            documentScrollSaveTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.saveState()
            }
        }

        static func clampScrollFraction(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value >= 0, value <= 1 else { return nil }
            return value
        }

        /// 由 Core 保存完整的值类型 Session 快照；外部资源恢复时用原请求重建运行时 Session。
        func restoreExtensionSession(from config: WindowConfig) {
            guard let extensionID = config.extensionID,
                  let reference = config.extensionStateReference else {
                extensionSession = nil
                return
            }
            do {
                if let envelope = try ExtensionHost.shared.stateStore.load(extensionID: extensionID, reference: reference),
                   ExtensionHost.shared.isExtensionAvailable(extensionID) {
                    let session = try JSONDecoder().decode(ContentSession.self, from: envelope.payload)
                    guard session.extensionID == extensionID else {
                        throw ExtensionStateStoreError.namespaceMismatch
                    }
                    try NavigatorContributionValidator.validate(session)
                    if session.request.resources.isEmpty {
                        extensionSession = session
                    } else {
                        extensionSession = nil
                        rebuildExternalExtensionSession(
                            from: session,
                            stateReference: reference,
                            expectedStateID: config.id
                        )
                    }
                } else {
                    extensionSession = unavailableExtensionSession(extensionID: extensionID, reference: reference)
                }
            } catch {
                NSLog("Extension snapshot restore failed: \(error)")
                extensionSession = unavailableExtensionSession(extensionID: extensionID, reference: reference)
            }
        }

        func unavailableExtensionSession(extensionID: String, reference: String) -> ContentSession {
            ContentSession(
                extensionID: extensionID,
                providerID: "unavailable",
                request: .restoredSession(extensionID: extensionID, stateReference: reference),
                presentation: .unavailable(
                    titleKey: "Extension Session Unavailable",
                    messageKey: "Extension Session Restore Failed"
                ),
                stateReference: reference
            )
        }

}
