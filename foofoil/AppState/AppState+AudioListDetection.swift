//
//  AppState+AudioListDetection.swift
//  foofoil
//
//  Created by tolg on 2026/9/24.
//

import AppKit
import Foundation

/// 单个普通音频文件打开后的同目录音乐列表检测与安装。
///
/// 检测在起播之后异步执行，与封面读取并行；目录授权与封面共用同一次请求，
/// 检测到 CUE 谱表或带轨号规律的同类型文件时询问用户，同意后改为加载列表。
extension AppState {
    /// 启动一次列表检测；非普通音频（CUE、SACD ISO、视频）直接忽略。
    func detectAudioListIfNeeded(for url: URL) {
        guard Self.isAudioFile(url: url),
              !FileListGrouper.isCueFile(url),
              !FileListGrouper.isSACDISOFile(url) else { return }
        cancelAudioListDetection()
        let generation = audioListDetectionGeneration
        audioListDetectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // 目录授权与封面读取共用：需要时弹一次面板，用户拒绝则不再打扰。
            _ = await self.ensureAudioDirectoryAccess(for: url)
            guard !Task.isCancelled,
                  self.audioListDetectionGeneration == generation,
                  AudioMetadataLoader.isCoverDirectoryAccessible(for: url),
                  self.isPresentingAudioFile(url) else { return }
            let match = await Task.detached(priority: .utility) {
                AudioListDetector.detect(for: url)
            }.value
            guard !Task.isCancelled,
                  self.audioListDetectionGeneration == generation,
                  self.isPresentingAudioFile(url),
                  let match else { return }
            guard self.confirmLoadDetectedAudioList(match, sourceURL: url) else { return }
            self.installDetectedAudioList(match, preferredURL: url)
        }
    }

    /// 取消未完成的列表检测；切换内容或安装列表前调用，避免过期结果覆盖新内容。
    func cancelAudioListDetection() {
        audioListDetectionTask?.cancel()
        audioListDetectionTask = nil
        audioListDetectionGeneration &+= 1
    }

    /// 当前箔片是否仍在呈现该音频文件（尚未切换到别的文件或列表）。
    func isPresentingAudioFile(_ url: URL) -> Bool {
        guard let current = currentAudioPresentationURL else { return false }
        return current.resolvingSymlinksInPath().standardizedFileURL.path
            == url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func confirmLoadDetectedAudioList(_ match: AudioListDetector.Match, sourceURL: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Music List Detected Title", comment: "")
        switch match {
        case .cue(let cueURL):
            alert.informativeText = String(
                format: NSLocalizedString("Music List Detected Cue Message Format", comment: ""),
                cueURL.lastPathComponent,
                sourceURL.lastPathComponent
            )
        case .files(let urls):
            alert.informativeText = String(
                format: NSLocalizedString("Music List Detected Files Message Format", comment: ""),
                urls.count,
                sourceURL.lastPathComponent
            )
        }
        alert.addButton(withTitle: NSLocalizedString("Load List", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Not Now", comment: ""))
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 检测结果就地替换当前单文件内容；沿用窗口 id，历史记录由单曲更新为列表。
    func installDetectedAudioList(_ match: AudioListDetector.Match, preferredURL: URL) {
        switch match {
        case .cue(let cueURL):
            installCueSheets(urls: [cueURL], preservesIdentity: true, preferredURL: preferredURL)
        case .files(let urls):
            installAudioList(urls: urls, preservesIdentity: true, preferredURL: preferredURL)
        }
    }
}
