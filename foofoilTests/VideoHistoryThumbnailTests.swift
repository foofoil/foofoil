import Testing
import AppKit
import AVFoundation
@testable import foofoil

struct VideoHistoryThumbnailTests {
    @Test func midpointAvoidsBlackOpeningFrame() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("sample.mov")
        let thumbnail = directory.appendingPathComponent("thumbnail.heic")
        let writer = try AVAssetWriter(outputURL: video, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input)
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<3 {
            var buffer: CVPixelBuffer?
            #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            for y in 0..<48 {
                for x in 0..<64 {
                    let offset = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
                    base[offset] = 0; base[offset + 1] = 0
                    base[offset + 2] = index == 0 ? 0 : 255; base[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            for _ in 0..<200 where !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            try #require(input.isReadyForMoreMediaData)
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(seconds: Double(index), preferredTimescale: 600)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        let generated = await Task.detached {
            HistoryThumbnailGenerator.generateThumbnail(for: video, kind: .video, destinationURL: thumbnail)
        }.value
        #expect(generated)
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: thumbnail)))
        let center = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(center.redComponent > 0.8)
        #expect(center.redComponent > center.greenComponent + 0.2, "RGB: \(center.redComponent), \(center.greenComponent), \(center.blueComponent)")
        #expect(center.redComponent > center.blueComponent + 0.2)
    }
}
