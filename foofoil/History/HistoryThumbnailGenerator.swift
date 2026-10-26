//
//  HistoryThumbnailGenerator.swift
//  foofoil
//
//  Created by tolg on 2026/7/15.
//

import Foundation
import AppKit
import AVFoundation
import PDFKit
import ImageIO
import QuickLookThumbnailing

/// 历史记录缩略图生成器，支持将图片与 PDF 生成为正方形的 HEIC 缩略图
public enum HistoryThumbnailGenerator {

    /// 历史缩略图最终的正方形边长（像素）。覆盖层卡片自适应列宽最大约 300pt，视网膜 2x 下约
    /// 600px，加上悬停放大后仍有余量，故取 640；旧数据不迁移，仅在缩略图重建时按新尺寸生成。
    public nonisolated static let pixelSize = 640

    /// 解码中间尺寸：取最终尺寸的 2 倍，保证居中裁成正方形后短边仍不缩水，
    /// 避免宽幅原图裁出的正方形被放大而发糊。
    private nonisolated static var decodePixelSize: Int { pixelSize * 2 }

    /// 生成缩略图并保存到指定路径
    /// - Parameters:
    ///   - url: 原文件路径（图片或 PDF）
    ///   - kind: 历史内容类型
    ///   - destinationURL: 缩略图保存的目标 HEIC 路径
    /// - Returns: 生成并保存成功返回 true，否则返回 false
    nonisolated public static func generateThumbnail(
        for url: URL,
        kind: HistoryContentKind,
        destinationURL: URL,
        customCoverURL: URL? = nil
    ) -> Bool {
        var finalImage: CGImage? = nil

        switch kind {
        case .image:
            // 使用 CGImageSource 快速载入，限制最长边避免将超大原图完全加载进内存
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.decodePixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            if let mediumCGImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                // 裁剪为正方形并缩放到最终像素尺寸
                finalImage = cropAndResize(mediumCGImage, to: Self.pixelSize)
            }

        case .pdf:
            // 提取 PDF 的第一页并转成 CGImage
            guard let document = PDFDocument(url: url), document.pageCount > 0,
                  let page = document.page(at: 0) else { return false }
            let box = page.bounds(for: .mediaBox)
            // 先按比例限制最大边生成一张稍大一点的页面图以提供裁剪余量
            let scale = Double(Self.decodePixelSize) / max(box.width, box.height)
            let size = NSSize(width: box.width * scale, height: box.height * scale)
            let nsImage = page.thumbnail(of: size, for: .mediaBox)
            if let tiffData = nsImage.tiffRepresentation,
               let source = CGImageSourceCreateWithData(tiffData as CFData, nil),
               let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                // 裁剪为正方形并缩放到最终像素尺寸
                finalImage = cropAndResize(cgImage, to: Self.pixelSize)
            }

        case .video:
            // 取中间时间点，避开常见片头黑场；独立读取不影响播放器位置。
            let asset = AVURLAsset.media(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: Self.decodePixelSize, height: Self.decodePixelSize)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let semaphore = DispatchSemaphore(value: 0)
            var generatedImage: CGImage?
            Task {
                let duration = (try? await asset.load(.duration).seconds) ?? 0
                let time = CMTime(seconds: Self.videoThumbnailTime(duration: duration), preferredTimescale: 600)
                generatedImage = try? await generator.image(at: time).image
                semaphore.signal()
            }
            semaphore.wait()
            if let cgImage = generatedImage {
                finalImage = cropAndResize(cgImage, to: Self.pixelSize)
            }

        case .quickLook:
            // Quick Look 的内容缩略图来自系统预览服务；不能截取远程视图的图层。
            // 仅在后台索引队列等待，Finder 图标在主线程获取并完整居中保留。
            let semaphore = DispatchSemaphore(value: 0)
            var previewImage: CGImage?
            Task {
                let request = QLThumbnailGenerator.Request(
                    fileAt: url,
                    size: CGSize(width: Self.decodePixelSize, height: Self.decodePixelSize),
                    scale: 1,
                    representationTypes: .thumbnail
                )
                if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
                   representation.type == .thumbnail {
                    previewImage = representation.cgImage
                }
                semaphore.signal()
            }
            semaphore.wait()
            if let previewImage {
                finalImage = cropAndResize(previewImage, to: Self.pixelSize)
            } else {
                finalImage = DispatchQueue.main.sync {
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    var rect = CGRect(x: 0, y: 0, width: Self.pixelSize, height: Self.pixelSize)
                    return icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                }.flatMap { fitFileIcon($0) }
            }

        case .audio:
            // 用户拖入替换的封面优先于内嵌/同目录封面
            if let customCoverURL,
               FileManager.default.fileExists(atPath: customCoverURL.path),
               let artwork = NSImage(contentsOf: customCoverURL),
               let cgImage = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                finalImage = cropAndResize(cgImage, to: Self.pixelSize)
            } else {
                let info = AudioMetadataLoader.loadSynchronously(from: url)
                if let artwork = info.artwork,
                   let cgImage = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    finalImage = cropAndResize(cgImage, to: Self.pixelSize)
                }
            }

        default:
            return false
        }

        guard let image = finalImage else { return false }
        return write(image, to: destinationURL)
    }

    /// Finder 图标保留透明边缘和完整轮廓；HEIC 使用白色底板。
    nonisolated private static func fitFileIcon(_ image: CGImage) -> CGImage? {
        let size = Self.pixelSize
        guard let context = CGContext(data: nil, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let scale = Double(size) * 0.8 / Double(max(image.width, image.height))
        let width = Double(image.width) * scale
        let height = Double(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (Double(size) - width) / 2,
                                      y: (Double(size) - height) / 2, width: width, height: height))
        return context.makeImage()
    }

    /// 远程音乐封面仅解码缩略尺寸，并沿用历史统一的正方形 HEIC 缓存。
    nonisolated static func videoThumbnailTime(duration: Double) -> Double {
        duration.isFinite && duration > 0 ? duration / 2 : 0
    }

    nonisolated static func generateArtworkThumbnail(data: Data, destinationURL: URL) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.decodePixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary),
              let thumbnail = cropAndResize(image, to: Self.pixelSize) else { return false }
        return write(thumbnail, to: destinationURL)
    }

    /// 多分区音频列表的历史缩略图：按分区顺序把各分区封面铺进固定四宫格（最多四张）。
    /// 不足四张时右下留空，画布始终保持方形，避免横向图片被历史卡片裁切。
    /// 少于两张封面时不生成，由调用方回退到单封面缩略图。
    public static func generateGridThumbnail(images: [NSImage], destinationURL: URL) -> Bool {
        let limited = Array(images.prefix(4))
        guard limited.count >= 2 else { return false }

        let columns = 2
        let rows = 2
        let gap = 4
        // 每个单元格加上间隔后整体正好等于单封面缩略图的边长，保证两类缩略图分辨率一致。
        let cellSize = (pixelSize - gap) / columns
        let width = columns * cellSize + (columns - 1) * gap
        let height = rows * cellSize + (rows - 1) * gap
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return false }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for (index, image) in limited.enumerated() {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let cell = cropAndResize(cgImage, to: cellSize) else { continue }
            let column = index % columns
            let row = index / columns
            // CGContext 原点在左下角，按视觉顺序自上而下摆放。
            let x = column * (cellSize + gap)
            let y = height - cellSize - row * (cellSize + gap)
            context.draw(cell, in: CGRect(x: x, y: y, width: cellSize, height: cellSize))
        }

        guard let grid = context.makeImage() else { return false }
        return write(grid, to: destinationURL)
    }

    /// 以 HEIC 格式写入目标文件（质量 70%）。
    nonisolated private static func write(_ image: CGImage, to destinationURL: URL) -> Bool {
        // 确保目标的父级目录存在
        let directory = destinationURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.70] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return false }
        return (try? ContentCache.shared.write(data as Data, to: destinationURL)) != nil
    }

    /// 将视图已展示的封面写入该窗口的历史缩略图并返回落盘路径。
    /// 无 imagePath 的扩展音频走不到后台索引，这是它们唯一的缩略图来源。
    public static func writeDisplayedArtwork(_ image: NSImage, historyID: UUID) -> URL? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let thumbnail = cropAndResize(cgImage, to: Self.pixelSize) else { return nil }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("foofoil", isDirectory: true)
        let destinationURL = root.appendingPathComponent("Thumbnails")
            .appendingPathComponent("\(historyID.uuidString).heic")
        try? FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard write(thumbnail, to: destinationURL) else { return nil }
        return destinationURL
    }

    /// 将 CGImage 居中裁剪为正方形，并使用高插值质量缩放到 targetSize × targetSize 像素
    nonisolated private static func cropAndResize(_ image: CGImage, to targetSize: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        let size = min(width, height)
        let x = (width - size) / 2
        let y = (height - size) / 2

        // 居中裁剪出正方形区域
        guard let cropped = image.cropping(to: CGRect(x: x, y: y, width: size, height: size)) else { return nil }

        // 缩放到目标大小
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetSize,
            height: targetSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            // HEIC 缩略图不需要透明度；使用无 Alpha 的 RGBX 位图可避免编码器额外分配 Alpha 通道。
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: targetSize, height: targetSize))
        return context.makeImage()
    }
}
