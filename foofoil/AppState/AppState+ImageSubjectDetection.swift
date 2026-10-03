//
//  AppState+ImageSubjectDetection.swift
//  foofoil
//
//  Created by tolg on 2026/10/3.
//

import Foundation

/// 图片箔载入后的主体检测：只为"提取图片主体"菜单项准备可用性，不打扰用户。
///
/// Vision 在后台队列执行，结果按图片路径去重，同图不会因为视图反复出现而重复推理；
/// 换图或重置内容会取消在途检测并丢弃过期结果，避免旧图的决定点亮新图的菜单项。
extension AppState {
    /// 图片开始显示后启动一次检测；非光栅图片箔、同图已检测或正在检测时直接返回。
    func detectImageSubjectIfNeeded(for url: URL) {
        // 主体检测与图片 OCR 共用同一套光栅图片门禁（网页、PDF、SVG、音视频、Quick Look 都排除）。
        guard canExtractTextFromImage,
              imageURL == url,
              imageSubjectDetectedURL != url,
              imageSubjectDetectionTask == nil else { return }
        let generation = imageSubjectDetectionGeneration
        imageSubjectDetectionTask = Task { @MainActor [weak self] in
            let detected = await Task.detached(priority: .utility) {
                ImageSubjectExtractor.hasSubject(url: url)
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.imageSubjectDetectionGeneration == generation,
                  self.imageURL == url else { return }
            self.imageSubjectDetectedURL = url
            self.hasExtractableImageSubject = detected
            self.imageSubjectDetectionTask = nil
        }
    }

    /// 取消未完成的主体检测；由 `imageURL` 变更与内容重置调用。
    func cancelImageSubjectDetection() {
        imageSubjectDetectionTask?.cancel()
        imageSubjectDetectionTask = nil
        imageSubjectDetectionGeneration &+= 1
    }
}
