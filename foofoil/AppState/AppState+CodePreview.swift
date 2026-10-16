//
//  AppState+CodePreview.swift
//  foofoil
//

import Foundation

extension AppState {
    /// 当前只读文本是否为可识别语言的代码文件；压缩包内条目依据其原始文件名判断。
    /// Markdown、网页、图片等其他内容路由不属于代码预览。
    var codeLanguageID: String? {
        guard let textURL, !isMarkdownDocument, imageURL == nil, webURL == nil, extensionSession == nil else { return nil }
        return CodeLanguage.languageID(forFileName: originalImageName ?? textURL.lastPathComponent)
    }

    /// 内容以代码形式呈现（WebKit 预览或原生回退）：默认字体为等宽，字体筛选也随之切换为等宽。
    var presentsAsCode: Bool { codeLanguageID != nil }

    /// WebKit 代码预览的语言：仅在已识别语言且未超过大小门槛时返回；否则由原生只读视图承接。
    var webCodePreviewLanguageID: String? {
        guard let language = codeLanguageID, CodeLanguage.allowsWebPreview(byteCount: text.utf8.count) else { return nil }
        return language
    }
}
