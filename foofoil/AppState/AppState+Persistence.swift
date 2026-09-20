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
            guard !isBatchUpdating, !isAdjustingDocumentStyling else { return }
            let config = toConfig()
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if imageURL != nil || webURL != nil || textURL != nil || extensionSession != nil || !trimmedText.isEmpty {
                HistoryManager.shared.addToHistory(config)
            }
        }

        public func loadConfig(_ config: WindowConfig) {
            // 即使连续载入同一条历史，也必须使上一轮异步恢复失效。
            currentMediaRouteGeneration &+= 1
            isLoading = false
            isBatchUpdating = true
            defer {
                isBatchUpdating = false
                saveState()
                updateRenderedMarkdown()
            }

            // 载入历史项必须沿用原 UUID，否则随后的自动保存会创建一条重复历史。
            self.id = config.id
            self.sourceFingerprint = config.sourceFingerprint
            self.isPinned = config.isPinned
            self.opacity = config.opacity
            self.originalImageName = config.originalImageName
            self.imageSource = config.imageSource
            self.showBorder = config.showBorder
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

            if let path = config.imagePath {
                let url = URL(fileURLWithPath: path)
                // 视频/音频经安全范围书签恢复沙盒访问（重启后路径直接不可达）
                if Self.isExternalMediaFileName(config.originalImageName ?? path) {
                    // 加载新配置前先释放旧的媒体授权
                    stopVideoAccess()
                    if let restored = Self.restoreVideoAccess(config: config, fallbackURL: url) {
                        self.accessingVideoURL = restored.accessedURL
                        self.videoBookmarkData = restored.bookmark
                        self.imageURL = restored.url
                        // 音频再恢复同目录封面文件夹的访问，保证封面在重启后仍可读取
                        if Self.isAudioFileName(config.originalImageName ?? path),
                           let sidecarBookmark = config.mediaSidecarBookmark,
                           let sidecar = Self.restoreSidecarCoverAccess(bookmark: sidecarBookmark) {
                            if sidecar.accessed { accessingSidecarDirectoryURL = sidecar.directory }
                            mediaSidecarBookmarkData = sidecar.refreshedBookmark ?? sidecarBookmark
                        }
                    } else {
                        self.videoBookmarkData = nil
                        self.mediaSidecarBookmarkData = nil
                        self.imageURL = nil
                    }
                } else if FileManager.default.fileExists(atPath: url.path) {
                    self.imageURL = url
                } else {
                    self.imageURL = nil
                }
            } else {
                self.imageURL = nil
            }

            // 扩展音频（DSF/DFF/SACD 经 Hi-Fi 播放，含目录列表）不占用 imageURL，
            // 同目录封面书签必须独立于 imagePath 恢复，否则每次重启都会重新弹出目录授权。
            if config.imagePath == nil, accessingSidecarDirectoryURL == nil {
                if let bookmark = config.mediaSidecarBookmark,
                   let sidecar = Self.restoreSidecarCoverAccess(bookmark: bookmark) {
                    if sidecar.accessed { accessingSidecarDirectoryURL = sidecar.directory }
                    mediaSidecarBookmarkData = sidecar.refreshedBookmark ?? bookmark
                } else if config.mediaSidecarBookmark == nil {
                    mediaSidecarBookmarkData = nil
                }
            }

            if let webStr = config.webURLString, let url = URL(string: webStr) {
                self.webURL = url
            } else {
                self.webURL = nil
            }

            if let actualWebStr = config.actualWebURLString, let url = URL(string: actualWebStr) {
                self.actualWebURL = url
            } else {
                self.actualWebURL = nil
            }
            if let path = config.textPath {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: url.path) {
                    self.textURL = url
                    do {
                        self.text = try Self.readTextContent(from: url)
                    } catch {
                        self.text = config.text
                    }
                } else {
                    self.textURL = nil
                    self.text = config.text
                }
            } else {
                self.textURL = nil
                self.text = config.text
            }
        }

        public func toConfig() -> WindowConfig {
            return WindowConfig(
                id: id,
                imagePath: imageURL?.path,
                webURLString: webURL?.absoluteString,
                actualWebURLString: actualWebURL?.absoluteString,
                originalImageName: originalImageName,
                imageSource: imageSource,
                text: text,
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
                textPath: textURL?.path,
                contentKind: HistoryContentKind.infer(from: WindowConfig(
                    id: id,
                    imagePath: imageURL?.path,
                    webURLString: webURL?.absoluteString,
                    originalImageName: originalImageName,
                    text: text,
                    isMarkdownPreview: isMarkdownPreview,
                    textPath: textURL?.path,
                    extensionID: extensionSession?.extensionID,
                    fileList: fileList?.isPresentable == true ? fileList : nil
                )),
                sourceFingerprint: sourceFingerprint,
                webZoom: webZoom,
                documentZoom: documentZoom,
                mediaPlaybackMode: mediaPlaybackMode,
                videoBookmark: videoBookmarkData,
                mediaSidecarBookmark: mediaSidecarBookmarkData,
                customCoverPath: customCoverURL?.path,
                extensionID: extensionSession?.extensionID,
                extensionStateReference: extensionStateReference,
                navigatorPanelSide: navigatorPanelSide,
                navigatorPanelVisibilityMode: navigatorPanelVisibilityMode,
                navigatorPanelWidth: navigatorPanelWidth,
                fileList: fileList?.isPresentable == true ? fileList : nil,
                documentScrollFile: extensionDocumentScrollFile,
                documentScrollFraction: extensionDocumentScrollFraction
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
