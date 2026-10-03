//
//  AppState+ImageTextDetection.swift
//  foofoil
//
//  Created by tolg on 2026/10/3.
//

import Foundation

/// 图片箔载入后的文字检测：既决定"提取文字"菜单项的可用性，也把 OCR 结果缓存下来供提取复用。
///
/// 与图片 OCR 走同一条 Vision 通道，空结果即认为图中无字、菜单项保持禁用；
/// 推理在后台队列执行，结果按图片路径去重，同图不会因为视图反复出现而重复推理；
/// 结论写入历史后，重开历史直接采用，不再重跑 OCR。换图或重置内容会取消在途检测并丢弃过期结果。
extension AppState {
    /// 图片开始显示后启动一次检测；非光栅图片箔、同图已检测或正在检测时直接返回。
    func detectImageTextIfNeeded(for url: URL) {
        // 文字检测与图片 OCR、主体检测共用同一套光栅图片门禁（网页、PDF、SVG、音视频、Quick Look 都排除）。
        guard canExtractTextFromImage,
              imageURL == url,
              imageTextDetectedURL != url,
              imageTextDetectionTask == nil else { return }
        let generation = imageTextDetectionGeneration
        imageTextDetectionTask = Task { @MainActor [weak self] in
            let text = await Task.detached(priority: .utility) {
                (try? ImageOCRIndexer.recognize(url: url)) ?? ""
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.imageTextDetectionGeneration == generation,
                  self.imageURL == url else { return }
            self.imageTextDetectedURL = url
            self.imageOCRText = text
            self.hasExtractableImageText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            self.imageTextDetectionTask = nil
            // OCR 结果随历史持久化，重开历史与后续提取都直接复用。
            self.saveState()
        }
    }

    /// 取消未完成的文字检测；由 `imageURL` 变更与内容重置调用。
    func cancelImageTextDetection() {
        imageTextDetectionTask?.cancel()
        imageTextDetectionTask = nil
        imageTextDetectionGeneration &+= 1
    }
}
