//  CodeLanguageTests.swift
//  foofoilTests
//

import AppKit
import Foundation
import Testing
@testable import foofoil

struct CodeLanguageTests {
    private static let resourceDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("foofoil/Resources/CodePreview")

    private struct Manifest: Decodable {
        let languages: [String]
    }

    @Test func recognizesExtensionsCaseInsensitively() {
        #expect(CodeLanguage.languageID(forFileName: "Main.SWIFT") == "swift")
        #expect(CodeLanguage.languageID(forFileName: "app.kt") == "kotlin")
        #expect(CodeLanguage.languageID(forFileName: "build.gradle.kts") == "kotlin")
        #expect(CodeLanguage.languageID(forFileName: "sample.zig") == "zig")
        #expect(CodeLanguage.languageID(forFileName: "config.toml") == "ini")
        #expect(CodeLanguage.languageID(forFileName: "ci.yml") == "yaml")
        #expect(CodeLanguage.languageID(forFileName: "component.tsx") == "typescript")
        #expect(CodeLanguage.languageID(forFileName: "header.h") == "c")
        #expect(CodeLanguage.languageID(forFileName: "Some.Plist") == "xml")
    }

    @Test func fixedFileNamesTakePrecedenceAndUseLastPathComponent() {
        #expect(CodeLanguage.languageID(forFileName: "Dockerfile") == "dockerfile")
        #expect(CodeLanguage.languageID(forFileName: "Dockerfile.dev") == "dockerfile")
        #expect(CodeLanguage.languageID(forFileName: "service.dockerfile") == "dockerfile")
        #expect(CodeLanguage.languageID(forFileName: "CMakeLists.txt") == "cmake")
        #expect(CodeLanguage.languageID(forFileName: "Makefile") == "makefile")
        #expect(CodeLanguage.languageID(forFileName: "/tmp/project/GNUmakefile") == "makefile")
        #expect(CodeLanguage.languageID(forFileName: "Gemfile") == "ruby")
        #expect(CodeLanguage.languageID(forFileName: ".zshrc") == "bash")
        #expect(CodeLanguage.languageID(forFileName: ".editorconfig") == "ini")
    }

    @Test func leavesUnknownAndContentRoutedFilesUnrecognized() {
        #expect(CodeLanguage.languageID(forFileName: "note.txt") == nil)
        #expect(CodeLanguage.languageID(forFileName: "photo.png") == nil)
        #expect(CodeLanguage.languageID(forFileName: "README") == nil)
        #expect(CodeLanguage.languageID(forFileName: "") == nil)
    }

    @Test func previewSizeBoundaryIsInclusiveAt512KiB() {
        #expect(CodeLanguage.allowsWebPreview(byteCount: 512 * 1024))
        #expect(!CodeLanguage.allowsWebPreview(byteCount: 512 * 1024 + 1))
    }

    @Test func openWhitelistIncludesEveryMappedExtension() {
        for ext in ["kt", "kts", "zig", "toml", "yaml", "yml", "json", "plist", "swift", "h", "rb", "conf", "md"] {
            #expect(AppState.textFilenameExtensions.contains(ext), "\(ext) 应在打开白名单中")
        }
        #expect(CodeLanguage.recognizedExtensions.isSubset(of: AppState.textFilenameExtensions))
    }

    @Test func everyMappedLanguageIsBundled() throws {
        let data = try Data(contentsOf: Self.resourceDirectory.appendingPathComponent("manifest.json"))
        let bundled = Set(try JSONDecoder().decode(Manifest.self, from: data).languages)
        #expect(bundled.count == 194)
        #expect(bundled.contains("zig"))

        var mapped = CodeLanguage.recognizedExtensions.compactMap { CodeLanguage.languageID(forFileName: "x.\($0)") }
        mapped += ["Dockerfile", "CMakeLists.txt", "Makefile", ".zshrc", ".npmrc", "Gemfile"].compactMap { CodeLanguage.languageID(forFileName: $0) }
        #expect(Set(mapped).isSubset(of: bundled), "映射指向了未打包的语言：\(Set(mapped).subtracting(bundled))")
    }
}

@MainActor
struct CodeTypographyTests {
    @Test func codeContentDefaultsToMonospacedFont() {
        let state = AppState(isIncognito: true)
        state.textURL = URL(fileURLWithPath: "/tmp/sample.swift")
        state.text = "let value = 1\n"
        #expect(state.documentFont(size: 14).isFixedPitch)
    }

    @Test func plainTextKeepsDefaultRoundedFont() {
        let state = AppState(isIncognito: true)
        state.textURL = URL(fileURLWithPath: "/tmp/note.txt")
        state.text = "hello\n"
        #expect(!state.documentFont(size: 14).isFixedPitch)
    }

    @Test func monospacedFilterKeepsFixedPitchFamilies() async {
        let catalog = await DocumentFontCatalog.load()
        #expect(catalog.monospacedFamilyNames.contains("Menlo"))
        #expect(!catalog.monospacedFamilyNames.contains("Helvetica"))
        let names = catalog.families(filter: .monospaced).map(\.name)
        #expect(names.contains("Menlo"))
        #expect(catalog.families(filter: .all).count == catalog.families.count)
    }
}
