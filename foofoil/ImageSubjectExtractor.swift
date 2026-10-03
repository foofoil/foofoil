//
//  ImageSubjectExtractor.swift
//  foofoil
//
//  Created by tolg on 2026/10/3.
//

import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// 用系统 Vision 的前景实例掩码提取图片主体，与"预览"的提取主体是同一套原生能力。
/// 判断针对整张图：前景实例集合非空即认为存在可与背景分离的主体，不依赖指针位置。
/// 项目默认主Actor隔离，这里显式退出：解码与推理都在后台队列执行。
nonisolated enum ImageSubjectExtractor {
    /// 存在性判断只需要模型自己的分析分辨率，小图解码更快、内存更省。
    static let analysisPixelLimit = 1024
    /// 输出主体的最大边长：更大的原图会被缩小，换取可预期的耗时与体积。
    static let outputPixelLimit = 3000

    private static let context = CIContext(options: [
        // 关闭工作色彩空间转换，否则抠出的主体颜色会相对原图偏移。
        .workingColorSpace: NSNull()
    ])

    /// 图中是否有可提取的主体；解码失败或没有前景实例返回 false。
    static func hasSubject(url: URL) -> Bool {
        foregroundObservation(url: url, pixelLimit: analysisPixelLimit) != nil
    }

    /// 把主体写成 PNG：主体外为透明，画面裁到主体外接范围。无主体或写盘失败返回 false。
    static func writeSubjectPNG(from url: URL, to destURL: URL) -> Bool {
        guard let (handler, observation) = foregroundObservation(url: url, pixelLimit: outputPixelLimit),
              let masked = try? observation.generateMaskedImage(
                  ofInstances: observation.allInstances,
                  from: handler,
                  croppedToInstancesExtent: true
              ) else { return false }

        let foreground = CIImage(cvPixelBuffer: masked)
        guard let cgImage = context.createCGImage(foreground, from: foreground.extent) else { return false }
        return writePNG(cgImage, to: destURL)
    }

    /// 一次请求同时给出处理器与观测：处理器持有原图，`generateMaskedImage` 要靠它取高分辨率结果。
    private static func foregroundObservation(
        url: URL,
        pixelLimit: Int
    ) -> (VNImageRequestHandler, VNInstanceMaskObservation)? {
        guard let image = uprightImage(url: url, pixelLimit: pixelLimit) else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              !observation.allInstances.isEmpty else { return nil }
        return (handler, observation)
    }

    /// 解码时按 EXIF 转正并限制最大边长：方向归一后掩码坐标才与原图一致，也避免整幅载入大图。
    private static func uprightImage(url: URL, pixelLimit: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelLimit,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary)
    }

    private static func writePNG(_ image: CGImage, to destURL: URL) -> Bool {
        // 先写同目录临时文件再替换，避免中途失败/退出留下半张图被当成有效抠图。
        let tempURL = destURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destURL)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }
}
