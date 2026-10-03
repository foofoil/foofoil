//
//  AppState+ImageSubjectDetection.swift
//  foofoil
//
//  Created by tolg on 2026/10/3.
//

import Foundation

/// 图片箔载入后的主体检测：既决定"提取图片主体"菜单项的可用性，也把抠图结果缓存下来供提取复用。
///
/// Vision 在后台队列执行，结果按图片路径去重，同图不会因为视图反复出现而重复推理；
/// 抠图 PNG 写入应用缓存并随历史持久化，重开历史与后续提取都直接复用。
/// 换图或重置内容会取消在途检测并丢弃过期结果，避免旧图的决定点亮新图的菜单项。
extension AppState {
    /// 图片开始显示后启动一次检测；非光栅图片箔、同图已检测或正在检测时直接返回。
    func detectImageSubjectIfNeeded(for url: URL) {
        // 主体检测与图片 OCR 共用同一套光栅图片门禁（网页、PDF、SVG、音视频、Quick Look 都排除）。
        guard canExtractTextFromImage,
              imageURL == url,
              imageSubjectDetectedURL != url,
              imageSubjectDetectionTask == nil,
              let cutoutURL = imageSubjectCacheURL() else { return }
        let generation = imageSubjectDetectionGeneration
        imageSubjectDetectionTask = Task { @MainActor [weak self] in
            // 一次请求同时给出"是否有主体"与抠图结果，避免检测与提取各跑一遍 Vision。
            let extracted = await Task.detached(priority: .utility) {
                ImageSubjectExtractor.writeSubjectPNG(from: url, to: cutoutURL)
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.imageSubjectDetectionGeneration == generation,
                  self.imageURL == url else { return }
            if !extracted {
                // 无主体或写盘失败：清理可能残留的旧缓存，避免被当作有效抠图。
                try? FileManager.default.removeItem(at: cutoutURL)
            }
            self.imageSubjectDetectedURL = url
            self.hasExtractableImageSubject = extracted
            self.imageSubjectCutoutURL = extracted ? cutoutURL : nil
            self.imageSubjectDetectionTask = nil
            // 主体结论与抠图路径随历史持久化，重开历史不再重跑 Vision。
            self.saveState()
        }
    }

    /// 取消未完成的主体检测；由 `imageURL` 变更与内容重置调用。
    func cancelImageSubjectDetection() {
        imageSubjectDetectionTask?.cancel()
        imageSubjectDetectionTask = nil
        imageSubjectDetectionGeneration &+= 1
    }
}
