import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import foofoil

@MainActor
struct ShareContentTests {
    private func sharingMenuAccepts(_ types: [[String]]) throws -> Bool {
        let plugins = try #require(Bundle(for: AppDelegate.self).builtInPlugInsURL)
        let data = try Data(contentsOf: plugins.appendingPathComponent("foofoilShareExtension.appex/Contents/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let extensionInfo = try #require(plist["NSExtension"] as? [String: Any])
        let attributes = try #require(extensionInfo["NSExtensionAttributes"] as? [String: Any])
        let rule = try #require(attributes["NSExtensionActivationRule"] as? String)
        return NSPredicate(format: rule).evaluate(with: [
            "extensionItems": [["attachments": types.map { ["registeredTypeIdentifiers": $0] }]]
        ])
    }

    @Test func sharingMenuKeepsSupportedContentAndUnspecifiedFileURLs() throws {
        for type in ["public.png", "com.adobe.pdf", "public.mp3", "public.mpeg-4", "public.plain-text",
                     "public.folder", "org.idpf.epub-container", "app.foofoil.audio.dsf", "public.iso-image",
                     "org.openxmlformats.wordprocessingml.document"] {
            #expect(try sharingMenuAccepts([["public.file-url", type]]))
        }
        #expect(try sharingMenuAccepts([["public.url"]]))
        #expect(try sharingMenuAccepts([["public.file-url", "public.data"]]))
        #expect(try sharingMenuAccepts([["public.file-url"]]))
        // 来源可附带自己的辅助类型；辅助元数据不能把通用文件 URL 误判为不支持。
        #expect(try sharingMenuAccepts([["public.file-url", "com.example.source-metadata"]]))
    }

    @Test func sharingMenuRejectsKnownUnsupportedFilesEvenWithURLRepresentation() throws {
        for type in ["public.zip-archive", "com.apple.disk-image-udif", "com.apple.application-bundle",
                     "public.executable", "com.apple.installer-package-archive"] {
            #expect(try !sharingMenuAccepts([["public.file-url", "public.url", type]]))
        }
        #expect(try !sharingMenuAccepts([["public.file-url", "public.png"], ["public.file-url", "public.zip-archive"]]))
        #expect(try !sharingMenuAccepts([]))
    }

    @Test func textAndWebsiteLinksPreserveContentWithoutClipboard() throws {
        for content in [SharedContentLink.text("中文 & # Markdown\nsecond line + 100%"),
                        .website(URL(string: "https://music.apple.com/cn/album/name/123?i=456&l=en")!)] {
            let url = try #require(content.url)
            #expect(SharedContentLink(url: url) == content)
        }
        #expect(SharedContentLink.website(URL(string: "file:///etc/passwd")!).url == nil)
        #expect(SharedContentLink(url: URL(string: "foofoil://share?url=javascript:alert(1)")!) == nil)
        #expect(SharedContentLink(url: URL(string: "foofoil://share?text=a&text=b")!) == nil)
        #expect(SharedContentLink.text(String(repeating: "a", count: SharedContentLink.maximumTextBytes + 1)).url == nil)
    }

    @Test func urlRepresentationWinsOverDescriptiveText() async throws {
        let provider = NSItemProvider()
        let website = URL(string: "https://music.apple.com/cn/album/title/123?i=456")!
        provider.registerItem(forTypeIdentifier: UTType.url.identifier, loadHandler: { completion, _, _ in
            completion?(website as NSURL, nil)
        })
        provider.registerItem(forTypeIdentifier: UTType.plainText.identifier, loadHandler: { completion, _, _ in
            completion?("Album title" as NSString, nil)
        })
        let result = try await SharedItemLoader.load(provider)
        #expect(SharedContentLink(url: result) == .website(website))
    }

    @Test func finderDirectoryKeepsOriginalPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = NSItemProvider(item: directory as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let loaded = try await SharedItemLoader.load(provider)
        #expect(loaded == directory)
        #expect(try SharedFileImport.persist([loaded]) == [directory])
    }

    @Test func exportedDocumentSurvivesProviderAndExtensionTemporaryFileRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Original.pdf")
        let data = Data("%PDF-1.7 share-test".utf8)
        try data.write(to: source)
        let provider = NSItemProvider()
        provider.suggestedName = "Preview Document"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completion in
            completion(source, false, nil)
            return nil
        }
        let staged = try await SharedItemLoader.load(provider)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        #expect(ShareStaging.isStaged(staged))
        #expect(staged.lastPathComponent == "Preview Document.pdf")
        try FileManager.default.removeItem(at: source)
        let imported = try #require(try SharedFileImport.persist([staged], root: root.appendingPathComponent("Imported")).first)
        try FileManager.default.removeItem(at: staged)
        #expect(try Data(contentsOf: imported) == data)
        #expect(!ShareStaging.isStaged(imported))
    }

    @Test func dataOnlyImageProviderMaterializesAnImageFile() async throws {
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let provider = NSItemProvider()
        provider.suggestedName = "Shared Image"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        let staged = try await SharedItemLoader.load(provider)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        #expect(staged.pathExtension == "png")
        #expect(try Data(contentsOf: staged) == data)
    }

    @Test func failedImportRollsBackOnlyItsOwnCopies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("first.txt")
        try Data("first".utf8).write(to: source)
        let staged = try ShareStaging.copy(source)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        let missing = staged.deletingLastPathComponent().appendingPathComponent("missing.txt")
        let importedRoot = root.appendingPathComponent("Imported")
        #expect(throws: (any Error).self) { try SharedFileImport.persist([staged, missing], root: importedRoot) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: importedRoot.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}
