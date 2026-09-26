//
//  AudioListDetection.swift
//  foofoil
//
//  Created by tolg on 2026/9/24.
//

import Foundation

/// 单个普通音频文件同目录音乐列表的识别规则。
///
/// 两类线索，CUE 优先：
/// 1. CUE 谱表：与音频同名的 `.cue`，或同目录下引用该音频的其它 `.cue`（多文件专辑常见）；
/// 2. 文件名轨号规律：与当前文件同扩展名、同前缀模板、轨号互不重复的一组音频文件。
///    例如 `01 - Song.flac`、`02 - Song.flac`，`Track01.mp3`、`Track02.mp3`，`1-01 Song.dsf`。
///    前缀模板是轨号之前的文本（空、`Track `、`CD1 - `、`周杰伦 - ` 等），轨号后必须紧跟分隔符或文件结尾；
///    纯数字年份、日期等前缀不构成合法模板，避免把无关文件当成专辑。
nonisolated enum AudioListDetector {
    /// 疑似列表：CUE 谱表优先，其次是按轨号排序的文件序列。
    enum Match: Equatable, Sendable {
        case cue(URL)
        case files([URL])
    }

    /// 文件名中的轨号规律：同一家族的共同前缀 + 轨号。
    struct TrackName: Equatable, Sendable {
        var family: String
        var number: Int
    }

    /// 除同名 CUE 外，最多再解析多少个谱表来寻找引用当前音频的列表。
    static let maximumCueScanCount = 16

    /// 扫描音频所在目录，返回疑似同一列表；目录不可读（沙盒未授权）时返回 nil。
    static func detect(for url: URL, fileManager: FileManager = .default) -> Match? {
        let directory = url.deletingLastPathComponent()
        guard fileManager.isReadableFile(atPath: directory.path) else { return nil }
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let files = entries.filter { isRegularFile($0, fileManager: fileManager) }
        if let cueURL = matchingCue(for: url, in: files) { return .cue(cueURL) }
        let tracks = trackList(for: url, in: files)
        return tracks.count >= 2 ? .files(tracks) : nil
    }

    /// 解析文件名中的轨号规律；不满足模板（前缀非法、无分隔符、轨号为 0）时返回 nil。
    static func trackName(for fileName: String) -> TrackName? {
        let stem = (fileName as NSString).deletingPathExtension
        guard !stem.isEmpty else { return nil }
        let fullRange = NSRange(location: 0, length: (stem as NSString).length)

        // 先识别“碟号-轨号”（1-01、01.02）：家族包含碟号，跨碟的相同轨号不会互相去重。
        if let match = discTrackRegex?.firstMatch(in: stem, range: fullRange) {
            let prefix = match.group(1, in: stem) ?? ""
            if isPlausiblePrefix(prefix),
               let disc = match.group(2, in: stem),
               let number = match.group(3, in: stem).flatMap(Int.init),
               number > 0 {
                return TrackName(family: "disc\(disc):\(normalizedFamily(prefix))", number: number)
            }
        }

        // 普通轨号：从左到右取第一个可信解释。`CD1 - 06` 这类“关键词 + 碟号”前缀说明
        // 前面的数字只是碟号，应继续看下一个候选；曲名里的数字不会抢走真正的轨号。
        var candidates: [(prefix: String, number: Int)] = []
        for match in trackCandidateRegex?.matches(in: stem, range: fullRange) ?? [] {
            guard let numberRange = Range(match.range(at: 1), in: stem) else { continue }
            let prefix = String(stem[stem.startIndex..<numberRange.lowerBound])
            guard prefix.count <= 60, isPlausiblePrefix(prefix),
                  let number = Int(stem[numberRange]), number > 0 else { continue }
            candidates.append((prefix, number))
        }
        for (index, candidate) in candidates.enumerated() {
            let isFollowedByDiscPrefix = candidates[(index + 1)...].contains {
                isKeywordDiscCore(normalizedFamily($0.prefix))
            }
            guard !isFollowedByDiscPrefix else { continue }
            return TrackName(family: "track:\(normalizedFamily(candidate.prefix))", number: candidate.number)
        }
        return nil
    }

    // MARK: - 内部实现

    /// 碟号与轨号之间是单个分隔符（1-01、01.02）；轨号后必须紧跟分隔符或文件结尾。
    private static let discTrackRegex = try? NSRegularExpression(
        pattern: "^(.{0,60}?)(\\d{1,2})[._-](\\d{1,2})(?:[\\s._\\-–—)\\]]|$)"
    )
    /// 轨号候选：数字后紧跟分隔符或文件结尾，数字不能是更长数字串的一部分。
    private static let trackCandidateRegex = try? NSRegularExpression(
        pattern: "(?<![0-9])(\\d{1,2})(?:[\\s._\\-–—)\\]]|$)"
    )
    /// 前缀本身就是常见碟/轨关键词时不再要求以分隔符结尾（Track01、CD1-01）。
    private static let prefixKeywords: Set<String> = [
        "track", "trk", "tr", "disc", "disk", "cd", "vol", "volume",
        "part", "pt", "side", "chapter", "ch", "episode", "ep"
    ]

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    /// 同目录 CUE：同名优先，其次任意引用当前音频的谱表；谱表需能解析出至少两个曲目。
    private static func matchingCue(for url: URL, in files: [URL]) -> URL? {
        let cues = files.filter { $0.pathExtension.lowercased() == "cue" }
        guard !cues.isEmpty else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        let sameName = cues.filter { $0.deletingPathExtension().lastPathComponent.lowercased() == stem }
        let others = cues.filter { !sameName.contains($0) }.prefix(maximumCueScanCount)
        for cue in sameName + others {
            guard let sheet = CueSheetLoader.load(from: cue), sheet.tracks.count >= 2 else { continue }
            if references(sheet, audioURL: url) { return cue }
        }
        return nil
    }

    private static func references(_ sheet: CueSheet, audioURL: URL) -> Bool {
        let path = audioURL.resolvingSymlinksInPath().standardizedFileURL.path
        return sheet.tracks.contains { track in
            track.fileURL?.resolvingSymlinksInPath().standardizedFileURL.path == path
        }
    }

    /// 同扩展名的轨号文件；要求包含当前文件、至少两项且轨号互不重复。
    private static func trackList(for url: URL, in files: [URL]) -> [URL] {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, let anchor = trackName(for: url.lastPathComponent) else { return [] }
        var byNumber: [Int: URL] = [:]
        var hasDuplicateNumber = false
        for file in files where file.pathExtension.lowercased() == ext {
            guard let name = trackName(for: file.lastPathComponent), name.family == anchor.family else { continue }
            if byNumber.updateValue(file, forKey: name.number) != nil {
                hasDuplicateNumber = true
            }
        }
        guard !hasDuplicateNumber, byNumber.count >= 2, byNumber[anchor.number] != nil else { return [] }
        return byNumber.keys.sorted().compactMap { byNumber[$0] }
    }

    /// 前缀为空、以分隔符结尾，或本身就是碟/轨关键词时才认为模板可信。
    /// 前缀核心以数字结尾时更像年份或日期（2021-01-），只有“关键词 + 碟号”（CD1 -、Disc 2）例外。
    private static func isPlausiblePrefix(_ prefix: String) -> Bool {
        guard let rawLast = prefix.last else { return true }
        let normalized = normalizedFamily(prefix)
        if normalized.isEmpty { return true }
        if prefixKeywords.contains(normalized) { return true }
        // 前缀与轨号之间必须有分隔符，否则 `Song01` 也会被当成轨号。
        guard " ._-–—)]".contains(rawLast) else { return false }
        guard let core = normalized.last, core.isNumber else { return true }
        return isKeywordDiscCore(normalized)
    }

    /// “关键词 + 碟号”核心（cd1、disc 1）可信；纯数字核心（2021-01）不可信。
    private static func isKeywordDiscCore(_ normalized: String) -> Bool {
        if Int(normalized) != nil { return false }
        let parts = normalized.split(whereSeparator: { " ._-–—)]".contains($0) })
        if parts.count == 1, let token = parts.first {
            return keywordDiscSuffix(String(token)) != nil
        }
        guard parts.count == 2, Int(parts[1]) != nil else { return false }
        return prefixKeywords.contains(String(parts[0]))
    }

    /// `cd1`、`track2` 这类“关键词直接跟碟号”的词尾碟号；不是该形式时返回 nil。
    private static func keywordDiscSuffix(_ token: String) -> Int? {
        for keyword in prefixKeywords where token.hasPrefix(keyword) {
            if let disc = Int(token.dropFirst(keyword.count)) { return disc }
        }
        return nil
    }

    /// 家族前缀归一化：小写、去首尾空白与尾部分隔符，使 `CD1 - `、`cd1-` 归为同一家族。
    private static func normalizedFamily(_ prefix: String) -> String {
        var value = prefix.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = value.last, "._-–—)]".contains(last) {
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }
}

private extension NSTextCheckingResult {
    /// 取指定捕获组文本；组不存在或不匹配时返回 nil。
    nonisolated func group(_ index: Int, in text: String) -> String? {
        guard index < numberOfRanges, let range = Range(range(at: index), in: text) else { return nil }
        return String(text[range])
    }
}
