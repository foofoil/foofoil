//
//  AudioMetadata.swift
//  foofoil
//
//  Created by tolg on 2026/8/21.
//

import AppKit
import AVFoundation
import AudioToolbox
import UniformTypeIdentifiers

/// 从音频文件提取的展示信息；封面优先使用内嵌 artwork，其次同目录匹配的封面图。
nonisolated struct AudioTrackInfo {
    var title: String
    var taggedTitle: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var composer: String?
    var genre: String?
    var year: String?
    var trackNumber: String?
    var formatName: String?
    /// 从音轨格式描述读取的编码名称，不使用文件扩展名推测。
    var codecName: String?
    /// MusicKit 的音质标签；不代替实际采样率、位深或编码格式。
    var qualitySummary: String?
    var qualityIsLossless = false
    var sampleRate: Double?
    var bitDepth: Int?
    var bitRate: Double?
    var channelCount: Int?
    /// MIDI 轨道上的乐器 / 端口名；多轨时以 · 连接，与曲名分开显示。
    var instrumentName: String?
    var artwork: NSImage?
    /// 封面来自音频同目录文件时记录其位置；不参与持久化。
    var sidecarCoverURL: URL?

    static func fallback(fileName: String) -> AudioTrackInfo {
        AudioTrackInfo(title: (fileName as NSString).deletingPathExtension)
    }

    /// 无封面时的默认窗口内容尺寸，接近竖版专辑卡片。
    static let fallbackPresentationSize = NSSize(width: 400, height: 500)
    /// 初次打开音频时，窗口宽、高均不超过该值。
    static let initialWindowMaxLength: CGFloat = 500

    /// 按封面比例缩放，使窗口（含边框留白）宽高都不超过 `initialWindowMaxLength`。
    static func initialWindowSize(for contentSize: NSSize, inset: CGFloat) -> NSSize {
        guard contentSize.width > 0, contentSize.height > 0 else { return fallbackPresentationSize }
        let maxContent = max(1, initialWindowMaxLength - inset)
        let scale = min(1, maxContent / contentSize.width, maxContent / contentSize.height)
        return NSSize(
            width: contentSize.width * scale + inset,
            height: contentSize.height * scale + inset
        )
    }
}

/// 以文件头采样数为准的播放时钟。AVAsset.duration 对 FLAC 常偏短，导致 CUE 后几段起点漂移、末段进度条提前走满。
nonisolated struct AudioPlaybackTiming: Equatable, Sendable {
    var duration: Double
    var sampleRate: Double
    var sampleCount: Int64
    var timescale: CMTimeScale

    func time(from seconds: Double) -> CMTime {
        let scale = max(1, timescale)
        let value = Int64((max(0, seconds) * Double(scale)).rounded())
        return CMTime(value: value, timescale: scale)
    }
}

/// 供导航列表使用的轻量媒体时长读取器；音频优先走 AudioToolbox，视频使用 AVFoundation。
nonisolated enum MediaDurationLoader {
    static func duration(for url: URL, kind: FileListKind) async -> Double? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if kind == .audio {
            if AudioMetadataLoader.isMIDI(url) {
                return AudioMetadataLoader.midiDuration(for: url)
            }
            if let timing = AudioMetadataLoader.playbackTiming(for: url) {
                return timing.duration
            }
        }

        let asset = AVURLAsset.media(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}

nonisolated enum AudioMetadataLoader {
    /// 与音频文件同名或同目录常用封面文件名，按优先级尝试。
    static let sidecarImageExtensions = ["jpg", "jpeg", "png", "webp", "heic", "tif", "tiff", "gif"]
    static let conventionalCoverNames = [
        "cover", "folder", "artwork", "albumart", "front", "AlbumArt", "AlbumArtSmall", "封面"
    ]

    static func load(from url: URL, includeArtwork: Bool = true) async -> AudioTrackInfo {
        var info = AudioTrackInfo.fallback(fileName: url.lastPathComponent)
        info.formatName = formatName(for: url)
        if isMIDI(url) {
            // MIDI 没有 PCM 音轨，AVAsset 只会返回空元数据；改读 SMF 的 meta events。
            applyMIDIMetadata(from: url, to: &info)
        } else {
            let asset = AVURLAsset.media(url: url)
            let metadata = ((try? await asset.load(.commonMetadata)) ?? [])
                + ((try? await asset.load(.metadata)) ?? [])
            await applyMetadata(metadata, to: &info, includeArtwork: includeArtwork)

            if let tracks = try? await asset.loadTracks(withMediaType: .audio), let track = tracks.first {
                if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                    info.bitRate = Double(rate)
                }
                if let descriptions = try? await track.load(.formatDescriptions) {
                    applyFormatDescriptions(descriptions, to: &info)
                }
            }
            if info.bitDepth == nil {
                info.bitDepth = flacBitDepth(for: url)
            }
        }

        if includeArtwork, info.artwork == nil,
           let sidecar = sidecarCoverImageAndURL(for: url) {
            info.artwork = sidecar.image
            info.sidecarCoverURL = sidecar.url
        }
        return info
    }

    /// 供历史索引等后台队列同步读取；请勿在主线程调用。
    static func loadSynchronously(from url: URL) -> AudioTrackInfo {
        let semaphore = DispatchSemaphore(value: 0)
        var result = AudioTrackInfo.fallback(fileName: url.lastPathComponent)
        Task {
            result = await load(from: url)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    static func presentationSize(for info: AudioTrackInfo) -> NSSize {
        // 和图片模式保持一致：按点尺寸布局，与 SwiftUI `Image(nsImage:)` 绘制一致；
        // 仅在 size 无效时退回像素尺寸，避免 DPI 异常把封面压成 0/1。
        if let artwork = info.artwork, let size = layoutSize(artwork) {
            return size
        }
        return AudioTrackInfo.fallbackPresentationSize
    }

    /// MIDI/SMF 没有 PCM 音轨，按系统 MIDI 类型识别；`.mid`、`.midi`、`.kar` 都归入 `public.midi-audio`。
    static func isMIDI(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .midi)
    }

    /// 列表时长按 SMF 的速度表计算；不要用文件大小或固定 120 BPM 估算。
    static func midiDuration(for url: URL) -> Double? {
        let sequencer = AVAudioSequencer()
        guard (try? sequencer.load(from: url, options: [])) != nil else { return nil }
        guard let seconds = sequencer.tracks.map(\.lengthInSeconds).max(),
              seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    /// 读取 SMF 的标题、作者等 meta events；不启动音频引擎，也不合成声音。
    private static func applyMIDIMetadata(from url: URL, to info: inout AudioTrackInfo) {
        // SMF 没有独立的“序列标题”事件；只有第一轨（format 1 的 conductor track）的
        // track name 可以当曲名。后续轨道常写着 SmartMusic SoftSynth 等设备名，
        // 不能直接采用，否则所有文件都会显示同一个合成器名。
        let trackNames = SMFTrackNamesParser.trackNames(in: url)
        if let title = normalizedMIDITrackName(trackNames.first ?? nil),
           !isPlaceholderMIDITrackName(title) {
            info.taggedTitle = title
            info.title = title
        }

        // 乐器名仍然保留为次级信息；同一合成器的多个通道名去重后只显示一次。
        var seenInstruments = Set<String>()
        var instruments: [String] = []
        for (index, rawName) in trackNames.enumerated() {
            guard let name = normalizedMIDITrackName(rawName) else { continue }
            if index == 0, info.taggedTitle == name { continue }
            let key = normalizedMIDIInstrumentKey(name)
            guard seenInstruments.insert(key).inserted else { continue }
            instruments.append(name)
        }
        if !instruments.isEmpty {
            info.instrumentName = instruments.joined(separator: " · ")
        }

        let sequencer = AVAudioSequencer()
        guard (try? sequencer.load(from: url, options: [])) != nil else { return }
        let values = sequencer.userInfo
        func text(_ key: AVAudioSequencer.InfoDictionaryKey) -> String? {
            guard let value = values[key.rawValue] else { return nil }
            let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        info.artist = text(.artist) ?? info.artist
        info.album = text(.album) ?? info.album
        info.composer = text(.composer) ?? info.composer
        info.genre = text(.genre) ?? info.genre
        info.year = text(.year) ?? info.year
        info.trackNumber = text(.trackNumber) ?? info.trackNumber
        info.formatName = "MIDI"
    }

    private static func normalizedMIDITrackName(_ name: String?) -> String? {
        guard let value = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func normalizedMIDIInstrumentKey(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s*\\d+$", with: "", options: .regularExpression)
            .lowercased()
    }

    /// 常见 MIDI 设备/合成器名不是曲名；匹配时退回文件名。
    private static func isPlaceholderMIDITrackName(_ name: String) -> Bool {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
        let base = normalized.replacingOccurrences(
            of: "\\s*\\d+$", with: "", options: .regularExpression
        )
        if base.hasPrefix("smartmusic") { return true }
        return placeholderMIDITrackNames.contains(base)
    }

    private static let placeholderMIDITrackNames: Set<String> = [
        "microsoft gs wavetable synth", "gs wavetable synth", "wavetable synth",
        "general midi", "gm", "midi", "midi out", "midi port", "midi synth",
        "dls synth", "apple dls synth", "coreaudio", "core audio",
        "fluidsynth", "fluid synth", "timidity", "synthesizer", "synth",
        "conductor", "conductor track", "master track", "tempo track",
        "untitled", "unknown"
    ]

    /// 用 AudioFile 的采样帧数计算真实时长；FLAC 不要用 AVAsset.duration。
    static func playbackTiming(for url: URL) -> AudioPlaybackTiming? {
        if let timing = timingFromAVAudioFile(url) { return timing }
        return timingFromAudioFile(url)
    }

    private static func timingFromAVAudioFile(_ url: URL) -> AudioPlaybackTiming? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.processingFormat.sampleRate > 0
            ? file.processingFormat.sampleRate
            : file.fileFormat.sampleRate
        let frames = file.length
        guard sampleRate > 0, frames > 0 else { return nil }
        return makeTiming(duration: Double(frames) / sampleRate, sampleRate: sampleRate, sampleCount: frames)
    }

    private static func timingFromAudioFile(_ url: URL) -> AudioPlaybackTiming? {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID else {
            return nil
        }
        defer { AudioFileClose(fileID) }

        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(fileID, kAudioFilePropertyDataFormat, &asbdSize, &asbd) == noErr,
              asbd.mSampleRate > 0 else {
            return nil
        }

        var duration: TimeInterval = 0
        var durationSize = UInt32(MemoryLayout<TimeInterval>.size)
        if AudioFileGetProperty(fileID, kAudioFilePropertyEstimatedDuration, &durationSize, &duration) == noErr,
           duration > 0 {
            return makeTiming(
                duration: duration,
                sampleRate: asbd.mSampleRate,
                sampleCount: Int64((duration * asbd.mSampleRate).rounded())
            )
        }

        var packetCount: UInt64 = 0
        var packetSize = UInt32(MemoryLayout<UInt64>.size)
        guard AudioFileGetProperty(fileID, kAudioFilePropertyAudioDataPacketCount, &packetSize, &packetCount) == noErr,
              packetCount > 0 else {
            return nil
        }
        let framesPerPacket = max(1, asbd.mFramesPerPacket)
        let sampleCount = Int64(packetCount * UInt64(framesPerPacket))
        return makeTiming(
            duration: Double(sampleCount) / asbd.mSampleRate,
            sampleRate: asbd.mSampleRate,
            sampleCount: sampleCount
        )
    }

    private static func makeTiming(duration: Double, sampleRate: Double, sampleCount: Int64) -> AudioPlaybackTiming {
        let timescale = CMTimeScale(clamping: max(1, Int(sampleRate.rounded())))
        return AudioPlaybackTiming(
            duration: duration,
            sampleRate: sampleRate,
            sampleCount: sampleCount,
            timescale: timescale
        )
    }

    /// 优先用像素尺寸，避免内嵌封面 NSImage.size 尚未就绪或被 DPI 压成 0/1。
    static func reliableImageSize(_ image: NSImage) -> NSSize? {
        if let rep = image.representations.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }),
           rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return NSSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
        }
        if image.size.width > 0, image.size.height > 0 {
            return image.size
        }
        return nil
    }

    /// 图片箔布局用点尺寸，与 SwiftUI 按 `NSImage.size` 绘制一致；仅在 size 无效时退回像素。
    static func layoutSize(_ image: NSImage) -> NSSize? {
        if image.size.width > 0, image.size.height > 0 {
            return image.size
        }
        return reliableImageSize(image)
    }

    static func sidecarCoverCandidates(for audioURL: URL) -> [URL] {
        let directory = audioURL.deletingLastPathComponent()
        let base = audioURL.deletingPathExtension().lastPathComponent
        var candidates: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL) {
            let key = url.path
            if seen.insert(key).inserted {
                candidates.append(url)
            }
        }

        for ext in sidecarImageExtensions {
            append(directory.appendingPathComponent("\(base).\(ext)"))
        }
        for name in conventionalCoverNames {
            for ext in sidecarImageExtensions {
                append(directory.appendingPathComponent("\(name).\(ext)"))
            }
        }
        return candidates
    }

    static func sidecarCoverURL(for audioURL: URL) -> URL? {
        sidecarCoverCandidates(for: audioURL).first { candidate in
            loadSidecarImage(at: candidate) != nil
        }
    }

    static func sidecarCoverImage(for audioURL: URL) -> NSImage? {
        sidecarCoverImageAndURL(for: audioURL)?.image
    }

    static func sidecarCoverImageAndURL(for audioURL: URL) -> (image: NSImage, url: URL)? {
        for candidate in sidecarCoverCandidates(for: audioURL) {
            if let image = loadSidecarImage(at: candidate) {
                return (image, candidate)
            }
        }
        return nil
    }

    /// 检查目录是否可读，供同目录音频扫描使用。
    static func isCoverDirectoryAccessible(for audioURL: URL) -> Bool {
        FileManager.default.isReadableFile(atPath: audioURL.deletingLastPathComponent().path)
    }

    private static func loadSidecarImage(at url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    static func formatSampleRate(_ sampleRate: Double) -> String {
        let kilohertz = sampleRate / 1000
        let text: String
        if abs(kilohertz.rounded() - kilohertz) < 0.05 {
            text = String(Int(kilohertz.rounded()))
        } else {
            text = String(format: "%g", (kilohertz * 10).rounded() / 10)
        }
        return String(format: NSLocalizedString("%@ kHz", comment: ""), text)
    }

    static func formatBitRate(_ bitRate: Double) -> String {
        let kbps = max(1, Int((bitRate / 1000).rounded()))
        return String(format: NSLocalizedString("%@ kbps", comment: ""), "\(kbps)")
    }

    static func formatBitDepth(_ bitDepth: Int) -> String {
        String(format: NSLocalizedString("%d-bit", comment: ""), bitDepth)
    }

    /// FLAC 的 Core Media 格式描述常缺少位深，直接读取固定长度的 STREAMINFO 文件头。
    static func flacBitDepth(from header: Data) -> Int? {
        guard header.count >= 42,
              header.prefix(4) == Data("fLaC".utf8),
              header[4] & 0x7f == 0,
              Int(header[5]) << 16 | Int(header[6]) << 8 | Int(header[7]) == 34 else {
            return nil
        }

        let streamInfo = header[18..<26].reduce(UInt64(0)) { partial, byte in
            partial << 8 | UInt64(byte)
        }
        let bitDepth = Int((streamInfo >> 36) & 0x1f) + 1
        return (4...32).contains(bitDepth) ? bitDepth : nil
    }

    static func formatChannels(_ count: Int) -> String {
        switch count {
        case 1: return NSLocalizedString("Mono", comment: "")
        case 2: return NSLocalizedString("Stereo", comment: "")
        default: return String(format: NSLocalizedString("%d Channels", comment: ""), count)
        }
    }

    static func formatDuration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    static func formatTrackNumber(_ value: String) -> String {
        String(format: NSLocalizedString("Track %@", comment: ""), value)
    }

    private static func applyMetadata(_ items: [AVMetadataItem], to info: inout AudioTrackInfo, includeArtwork: Bool) async {
        if let title = await stringValue(items, identifiers: [.commonIdentifierTitle]), !title.isEmpty {
            info.title = title
            info.taggedTitle = title
        }
        info.artist = await stringValue(items, identifiers: [.commonIdentifierArtist])
        info.album = await stringValue(items, identifiers: [.commonIdentifierAlbumName])
        info.genre = await stringValue(items, identifiers: [
            .iTunesMetadataUserGenre,
            .commonIdentifierType,
            AVMetadataIdentifier(rawValue: "org.id3/TCON")
        ])
        info.composer = await stringValue(items, identifiers: [
            .iTunesMetadataComposer, AVMetadataIdentifier(rawValue: "org.id3/TCOM"), .commonIdentifierCreator
        ])
        info.albumArtist = await stringValue(items, identifiers: [
            .iTunesMetadataAlbumArtist, AVMetadataIdentifier(rawValue: "org.id3/TPE2")
        ])

        if let dateString = await stringValue(items, identifiers: [
            .commonIdentifierCreationDate,
            .iTunesMetadataReleaseDate
        ]) {
            info.year = year(from: dateString)
        }

        if let track = await stringValue(items, identifiers: [
            .id3MetadataTrackNumber,
            .iTunesMetadataTrackNumber
        ]) {
            info.trackNumber = normalizedTrackNumber(track)
        } else if let trackData = await dataValue(items, identifiers: [.iTunesMetadataTrackNumber]) {
            info.trackNumber = trackNumber(from: trackData)
        }

        if includeArtwork, info.artwork == nil, let artworkData = await dataValue(items, identifiers: [.commonIdentifierArtwork]) {
            info.artwork = NSImage(data: artworkData)
        }
    }

    private static func applyFormatDescriptions(_ descriptions: [CMFormatDescription], to info: inout AudioTrackInfo) {
        for description in descriptions {
            guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { continue }
            if asbd.mSampleRate > 0 {
                info.sampleRate = asbd.mSampleRate
            }
            // 有损编码通常不声明原始位深，不能拿解码后的 PCM 位数代替。
            if asbd.mBitsPerChannel >= 8 {
                info.bitDepth = Int(asbd.mBitsPerChannel)
            }
            if asbd.mChannelsPerFrame > 0 {
                info.channelCount = Int(asbd.mChannelsPerFrame)
            }
            let codec = fourCC(asbd.mFormatID)
            if !codec.isEmpty { info.codecName = displayName(forCodec: codec) ?? codec }
            if info.formatName == nil || info.formatName?.isEmpty == true {
                info.formatName = displayName(forCodec: codec) ?? codec
            } else if let codecName = displayName(forCodec: codec) {
                info.formatName = codecName
            }
            break
        }
    }

    private static func flacBitDepth(for url: URL) -> Int? {
        guard url.pathExtension.caseInsensitiveCompare("flac") == .orderedSame,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 42) else { return nil }
        return flacBitDepth(from: header)
    }

    private static func stringValue(_ items: [AVMetadataItem], identifiers: [AVMetadataIdentifier]) async -> String? {
        for identifier in identifiers {
            let matches = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
            for item in matches {
                if let string = try? await item.load(.stringValue), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return string.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let data = try? await item.load(.dataValue),
                   let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !string.isEmpty {
                    return string
                }
            }
        }
        return nil
    }

    private static func dataValue(_ items: [AVMetadataItem], identifiers: [AVMetadataIdentifier]) async -> Data? {
        for identifier in identifiers {
            let matches = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
            for item in matches {
                if let data = try? await item.load(.dataValue), !data.isEmpty {
                    return data
                }
                if let value = try? await item.load(.value) {
                    if let data = value as? Data, !data.isEmpty { return data }
                    if let image = value as? NSImage, let tiff = image.tiffRepresentation { return tiff }
                }
            }
        }
        return nil
    }

    private static func year(from string: String) -> String {
        let digits = string.prefix(4)
        if digits.count == 4, digits.allSatisfy(\.isNumber) {
            return String(digits)
        }
        return string
    }

    private static func normalizedTrackNumber(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = trimmed.firstIndex(of: "/") {
            let number = trimmed[..<slash].trimmingCharacters(in: .whitespaces)
            return number.isEmpty ? trimmed : number
        }
        return trimmed
    }

    private static func trackNumber(from data: Data) -> String? {
        // iTunes trkn 原子：4 字节保留 + 2 字节曲目 + 2 字节总数
        guard data.count >= 8 else { return nil }
        let number = Int(data[4]) << 8 | Int(data[5])
        return number > 0 ? "\(number)" : nil
    }

    private static func formatName(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        if let type = UTType(filenameExtension: ext), let name = type.localizedDescription, !name.isEmpty {
            return preferredShortFormatName(extension: ext) ?? name
        }
        return preferredShortFormatName(extension: ext) ?? ext.uppercased()
    }

    private static func preferredShortFormatName(extension ext: String) -> String? {
        switch ext {
        case "mp3": return "MP3"
        case "m4a", "aac": return "AAC"
        case "m4b": return "M4B"
        case "wav": return "WAV"
        case "aif", "aiff", "aifc": return "AIFF"
        case "caf": return "CAF"
        case "flac": return "FLAC"
        case "mid", "midi", "kar": return "MIDI"
        case "au", "snd": return "AU"
        default: return nil
        }
    }

    private static func displayName(forCodec codec: String) -> String? {
        switch codec.lowercased() {
        case "aac", "mp4a": return "AAC"
        case "alac": return "ALAC"
        case "flac": return "FLAC"
        case ".mp3", "mp3 ": return "MP3"
        case "lpcm", "twos", "sowt": return "PCM"
        case "ima4": return "IMA"
        default: return nil
        }
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes.map { $0 == 0 ? " " : Character(UnicodeScalar($0)) })
            .trimmingCharacters(in: .whitespaces)
    }
}

/// 按轨道顺序读取 SMF 的 track name。format 1 中后续轨道名是乐器/端口名，
/// 例如 SmartMusic SoftSynth，不能把第一个找到的名称当曲名。
private enum SMFTrackNamesParser {
    static func trackNames(in url: URL) -> [String?] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        let bytes = [UInt8](data)
        guard bytes.count >= 14,
              bytes[0] == 0x4D, bytes[1] == 0x54, bytes[2] == 0x68, bytes[3] == 0x64,
              let headerLengthValue = readUInt32(bytes, at: 4) else { return [] }
        let headerLength = Int(headerLengthValue)
        guard headerLength >= 6 else { return [] }

        var names: [String?] = []
        var chunkOffset = 8 + headerLength
        while chunkOffset + 8 <= bytes.count {
            guard let chunkLengthValue = readUInt32(bytes, at: chunkOffset + 4) else { return names }
            let chunkLength = Int(chunkLengthValue)
            let bodyStart = chunkOffset + 8
            let bodyEnd = bodyStart + chunkLength
            guard chunkLength >= 0, bodyEnd <= bytes.count else { return names }
            if bytes[chunkOffset] == 0x4D, bytes[chunkOffset + 1] == 0x54,
               bytes[chunkOffset + 2] == 0x72, bytes[chunkOffset + 3] == 0x6B {
                names.append(trackName(in: bytes, start: bodyStart, end: bodyEnd))
            }
            chunkOffset = bodyEnd
        }
        return names
    }

    private static func trackName(in bytes: [UInt8], start: Int, end: Int) -> String? {
        var index = start
        var runningStatus: UInt8?
        while index < end {
            guard let (_, afterDelta) = readVariableLength(bytes, at: index, end: end) else { return nil }
            index = afterDelta
            guard index < end else { return nil }

            var status = bytes[index]
            if status < 0x80 {
                guard let runningStatus else { return nil }
                status = runningStatus
            } else {
                index += 1
                runningStatus = status < 0xF0 ? status : nil
            }

            if status == 0xFF {
                guard index < end else { return nil }
                let type = bytes[index]
                index += 1
                guard let (length, dataStart) = readVariableLength(bytes, at: index, end: end) else { return nil }
                index = dataStart
                guard length >= 0, index + length <= end else { return nil }
                if type == 0x03 {
                    return decodeText(bytes[index..<(index + length)])
                }
                index += length
                continue
            }

            if status == 0xF0 || status == 0xF7 {
                guard let (length, dataStart) = readVariableLength(bytes, at: index, end: end) else { return nil }
                index = dataStart
                guard length >= 0, index + length <= end else { return nil }
                index += length
                continue
            }

            let dataCount: Int
            switch status & 0xF0 {
            case 0x80, 0x90, 0xA0, 0xB0, 0xE0: dataCount = 2
            case 0xC0, 0xD0: dataCount = 1
            default:
                switch status {
                case 0xF1, 0xF3: dataCount = 1
                case 0xF2: dataCount = 2
                default: dataCount = 0
                }
            }
            guard index + dataCount <= end else { return nil }
            index += dataCount
        }
        return nil
    }

    private static func readVariableLength(_ bytes: [UInt8], at offset: Int, end: Int) -> (Int, Int)? {
        var value = 0
        var index = offset
        for _ in 0..<4 {
            guard index < end else { return nil }
            let byte = bytes[index]
            index += 1
            value = (value << 7) | Int(byte & 0x7F)
            if byte & 0x80 == 0 { return (value, index) }
        }
        return nil
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func decodeText(_ slice: ArraySlice<UInt8>) -> String? {
        let data = Data(slice)
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

