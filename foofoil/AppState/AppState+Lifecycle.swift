//  AppState+Lifecycle.swift
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
        public func resetContent() {
            terminalSession?.onOutputSnapshotChanged = nil
            terminalSession?.stop()
            terminalSession = nil
            terminalConfiguration = nil
            relinquishAgentControl()
            ContentCache.shared.retire(ownedBodyPaths)
            stopVideoAccess()
            archiveSession?.close()
            archiveSession = nil
            fileOpenFeedback = []
            closesEmptyWindowAfterFileOpenFailure = false
            appleMusicItem = nil
            // 重置后的箔片是全新文档：先收起属于本箔的取色面板与样式面板，避免残留面板继续写回。
            (NSApplication.shared.delegate as? AppDelegate)?.dismissColorPanel(ownedBy: self)
            (NSApplication.shared.delegate as? AppDelegate)?.dismissDocumentStylePanel(ownedBy: self)
            currentMediaRouteGeneration &+= 1
            NotificationCenter.default.post(
                name: .willResetContent,
                object: self
            )

            cameraController?.stop()
            cameraController = nil
            isCamera = false
            isBatchUpdating = true
            self.originalImageName = nil
            self.customTitle = nil
            self.imageSource = nil
            self.imageURL = nil
            self.webURL = nil
            self.actualWebURL = nil
            self.textURL = nil
            self.text = ""
            // 重置后的箔没有内容，上一次的排版结果一并丢弃，避免残留到下一篇文档的预览。
            self.renderedMarkdown = NSAttributedString()
            self.renderedMarkdownIdentity = nil
            self.sourceFingerprint = nil
            self.imageScale = 1.0
            self.id = UUID()
            self.createdAt = Date()
            self.svgColor = nil
            // 重置按新窗口处理：空白箔无默认主题，旧自选颜色、主题与字体不带到新空白箔。
            self.backgroundColorHex = nil
            self.textColorHex = nil
            self.searchHighlightHex = nil
            self.contentSearch.reset()
            self.documentThemeId = nil
            self.documentFontName = nil
            self.documentLineSpacing = nil
            self.documentParagraphSpacing = nil
            self.mediaPlaybackMode = .sequentialLoop
            self.videoBookmarkData = nil
            self.clearCustomCover()
            self.extensionSession = nil
            self.extensionFallbackProviderID = nil
            self.extensionStateReference = nil
            self.fileList = nil
            self.fileListRevision = 0
            self.stopImageListSlideshow()
            self.builtInNavigatorContributions = []
            self.builtInNavigatorActionHandler = nil
            self.isNavigatorPanelExplicitlyVisible = false
            self.navigatorFocusedItemID = nil
            self.activeNavigatorContributionID = nil
            self.expandedNavigatorItemIDs = []
            isBatchUpdating = false

            NotificationCenter.default.post(
                name: .shouldResetWindowFrame,
                object: self
            )
        }

        /// 窗口关闭时显式结束扩展会话：会话 close 幂等，避免视图树延迟释放导致设备或临时文件在进程存活期间不释放。
        func endExtensionSessionOnWindowClose() {
            // 关闭后仍保留原包元数据，窗口最后一次 saveState 必须能写回原包来源。
            archiveSession?.close()
            currentMediaRouteGeneration &+= 1
            cancelAudioListDetection()
            guard extensionSession != nil else { return }
            extensionSession = nil
            extensionFallbackProviderID = nil
            extensionStateReference = nil
        }

        /// 在当前窗口内切换无痕状态；普通转无痕同时删除该箔的历史。
        @discardableResult
        func toggleIncognitoMode() -> Bool {
            if !isIncognito, HistoryRepository.shared.config(id: id)?.historyIsPinned == true {
                toast.show(NSLocalizedString("Favorited Foil Cannot Become Incognito", comment: ""), symbolName: "bookmark.fill", duration: .seconds(3))
                return false
            }

            if isIncognito {
                isIncognito = false
                HistoryRepository.shared.allowUpsertAfterDeletion(id: id)
                configureTerminalSnapshotSaving()
                persistManagedTextIfNeeded(createIfNeeded: true)
                saveState()
                toast.show(NSLocalizedString("Converted to Regular Foil Toast", comment: ""), symbolName: "checkmark")
            } else {
                // 先保护仍在窗口中使用的托管正文，再删除历史，避免正文随记录提前回收。
                saveState()
                isIncognito = true
                configureTerminalSnapshotSaving()
                HistoryManager.shared.removeFromHistory(toConfig())
                toast.show(NSLocalizedString("Converted to Incognito Foil Toast", comment: ""), usesIncognitoIcon: true)
            }
            return true
        }

        public func togglePin() {
            self.isPinned.toggle()
        }
        public func increaseOpacity() {
            self.opacity = opacity + 0.1
        }

        public func decreaseOpacity() {
            self.opacity = opacity - 0.1
        }

        public func increaseTextFontSize() {
            textFontSize += 1.0
        }

        public func decreaseTextFontSize() {
            textFontSize -= 1.0
        }

        public static func clampImageScale(_ value: Double) -> Double {
            max(minImageScale, min(maxImageScale, value))
        }

        public static func clampTextFontSize(_ value: Double) -> Double {
            max(minTextFontSize, min(maxTextFontSize, value))
        }

        public static func clampWebZoom(_ value: Double) -> Double {
            max(0.25, min(5.0, value))
        }

        public static func clampDocumentZoom(_ value: Double) -> Double {
            max(minDocumentZoom, min(maxDocumentZoom, value))
        }
}
