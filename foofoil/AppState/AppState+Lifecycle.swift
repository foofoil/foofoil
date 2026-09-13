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
            currentMediaRouteGeneration &+= 1
            NotificationCenter.default.post(
                name: .willResetContent,
                object: self
            )

            isBatchUpdating = true
            self.originalImageName = nil
            self.imageSource = nil
            self.imageURL = nil
            self.webURL = nil
            self.actualWebURL = nil
            self.textURL = nil
            self.text = ""
            self.sourceFingerprint = nil
            self.imageScale = 1.0
            self.id = UUID()
            self.createdAt = Date()
            self.svgColor = nil
            self.mediaPlaybackMode = .sequentialLoop
            self.videoBookmarkData = nil
            self.mediaSidecarBookmarkData = nil
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
            guard extensionSession != nil else { return }
            extensionSession = nil
            extensionFallbackProviderID = nil
            extensionStateReference = nil
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
