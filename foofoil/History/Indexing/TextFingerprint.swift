//
//  TextFingerprint.swift
//  foofoil
//
//  Created by tolg on 2026/9/22.
//

import Foundation

/// 文档正文的稳定指纹（跨进程一致），用于判断历史保存是否需要重建搜索分块。
nonisolated enum TextFingerprint {
    static func value(for text: String) -> String {
        // FNV-1a 64 位：比 Hasher 稳定，也不依赖随机种子，可安全写入数据库跨进程比较。
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var byteCount = 0
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
            byteCount += 1
        }
        return "\(byteCount)-\(String(hash, radix: 16))"
    }
}
