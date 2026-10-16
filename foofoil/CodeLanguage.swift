//
//  CodeLanguage.swift
//  foofoil
//

import Foundation

/// 只读代码预览的语言识别：文件名（大小写不敏感）→ highlight.js 语言 ID。
/// 只依据显式的扩展名与固定文件名规则，不做内容猜测；未命中的文件继续走原生只读文本。
nonisolated enum CodeLanguage {
    /// 超过该 UTF-8 字节数的代码直接使用原生只读视图，不创建 WebKit 预览。
    static let maximumPreviewByteCount = 512 * 1024

    private static let extensionTable: [String: String] = [
        "swift": "swift",
        "py": "python", "pyi": "python", "pyw": "python",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "typescript",
        "sh": "bash", "bash": "bash", "zsh": "bash",
        "c": "c", "h": "c",
        "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "hxx": "cpp",
        "java": "java",
        "kt": "kotlin", "kts": "kotlin",
        "zig": "zig",
        "go": "go",
        "rs": "rust",
        "cs": "csharp", "csx": "csharp",
        "m": "objectivec", "mm": "objectivec",
        "rb": "ruby", "rake": "ruby", "gemspec": "ruby", "podspec": "ruby",
        "php": "php",
        "sql": "sql",
        "lua": "lua",
        "dart": "dart",
        "scala": "scala", "sc": "scala",
        "groovy": "groovy", "gradle": "groovy",
        "pl": "perl", "pm": "perl",
        "r": "r",
        "json": "json", "jsonc": "json", "json5": "json",
        "toml": "ini", "ini": "ini", "cfg": "ini",
        "yaml": "yaml", "yml": "yaml",
        "xml": "xml", "xsd": "xml", "xsl": "xml", "xslt": "xml", "plist": "xml", "rss": "xml", "atom": "xml",
        "css": "css", "scss": "scss", "less": "less",
        "graphql": "graphql", "gql": "graphql",
        "dockerfile": "dockerfile",
        "cmake": "cmake",
        "mk": "makefile", "mak": "makefile",
        "diff": "diff", "patch": "diff",
        "ps1": "powershell", "psm1": "powershell", "psd1": "powershell",
        "proto": "protobuf",
        "hs": "haskell",
        "ex": "elixir", "exs": "elixir",
        "erl": "erlang", "hrl": "erlang",
        "lisp": "lisp", "lsp": "lisp", "el": "lisp",
        "scm": "scheme",
        "ml": "ocaml", "mli": "ocaml",
        "fs": "fsharp", "fsi": "fsharp", "fsx": "fsharp",
        "nim": "nim",
        "vb": "vbnet",
        "tcl": "tcl",
        "jl": "julia",
        "f90": "fortran", "f95": "fortran", "f03": "fortran",
        "ada": "ada", "adb": "ada", "ads": "ada",
        "coffee": "coffeescript",
        "vim": "vim",
        "nix": "nix",
        "ino": "arduino",
        "hx": "haxe",
        "vala": "vala",
        "cr": "crystal",
        "d": "d",
        "elm": "elm",
        "pony": "pony",
        "awk": "awk",
        "bat": "dos", "cmd": "dos",
        "tex": "latex", "sty": "latex", "cls": "latex",
        "styl": "stylus",
        "hbs": "handlebars", "handlebars": "handlebars",
        "erb": "erb",
        "haml": "haml",
        "properties": "properties",
        "wat": "wasm",
    ]

    /// 无扩展名或扩展名不具代表性的固定文件名（已小写）。
    private static let fileNameTable: [String: String] = [
        "dockerfile": "dockerfile",
        "cmakelists.txt": "cmake",
        "makefile": "makefile",
        "gnumakefile": "makefile",
        "gemfile": "ruby",
        "rakefile": "ruby",
        "podfile": "ruby",
        ".bashrc": "bash",
        ".bash_profile": "bash",
        ".zshrc": "bash",
        ".zprofile": "bash",
        ".profile": "bash",
        ".editorconfig": "ini",
        ".gitconfig": "ini",
        ".npmrc": "ini",
    ]

    /// 以 `Dockerfile.dev` 这类前缀命名的文件同样识别为 Dockerfile。
    private static let fileNamePrefixTable: [(prefix: String, language: String)] = [
        ("dockerfile.", "dockerfile"),
    ]

    /// 打开白名单（`AppState.textFilenameExtensions`）由同一份映射派生，避免两个列表互相遗漏。
    static var recognizedExtensions: Set<String> {
        Set(extensionTable.keys)
    }

    /// 根据文件名（可含目录，仅取最后一段）返回 highlight.js 语言 ID；未识别时返回 nil。
    /// 优先级：固定文件名 → 前缀文件名 → 扩展名。
    static func languageID(forFileName fileName: String) -> String? {
        let name = (fileName as NSString).lastPathComponent.lowercased()
        guard !name.isEmpty else { return nil }
        if let language = fileNameTable[name] {
            return language
        }
        if let rule = fileNamePrefixTable.first(where: { name.hasPrefix($0.prefix) }) {
            return rule.language
        }
        let ext = (name as NSString).pathExtension
        return extensionTable[ext]
    }

    /// 代码预览的大小门槛：超出时由原生只读视图承接。
    static func allowsWebPreview(byteCount: Int) -> Bool {
        byteCount <= maximumPreviewByteCount
    }
}
