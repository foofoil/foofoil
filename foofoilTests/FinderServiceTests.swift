import AppKit
import Testing
@testable import foofoil

@MainActor
struct FinderServiceTests {
    private class RecordingDelegate: AppDelegate {
        var openedURLs: [URL] = []
        override func openFilesInNewFoil(_ urls: [URL]) {
            openedURLs = urls
        }
    }

    @Test func servicePreservesMultipleFileAndFolderURLs() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let urls = [
            URL(fileURLWithPath: "/tmp/参考 图 #1.png"),
            URL(fileURLWithPath: "/tmp/参考目录", isDirectory: true),
            URL(fileURLWithPath: "/tmp/second.pdf")
        ]
        #expect(pasteboard.writeObjects(urls.map { $0 as NSURL }))
        let delegate = RecordingDelegate()
        var error: NSString?
        delegate.openInFoofoil(pasteboard, userData: nil, error: &error)
        #expect(error == nil)
        #expect(delegate.openedURLs == urls)
        #expect(delegate.didOpenFiles)
        #expect(delegate.responds(to: NSSelectorFromString("openInFoofoil:userData:error:")))
    }

    @Test func serviceRejectsEmptyTextAndWebURLInputsWithoutOpeningWindows() {
        for kind in 0..<3 {
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            if kind == 1 {
                pasteboard.setString("/tmp/not-a-selected-file.png", forType: .string)
            } else if kind == 2 {
                pasteboard.writeObjects([NSURL(string: "https://example.com/image.png")!])
            }
            let delegate = RecordingDelegate()
            var error: NSString?
            delegate.openInFoofoil(pasteboard, userData: nil, error: &error)
            #expect(error != nil)
            #expect(delegate.openedURLs.isEmpty)
            #expect(!delegate.didOpenFiles)
            #expect(delegate.windowControllers.isEmpty)
        }
    }
}
