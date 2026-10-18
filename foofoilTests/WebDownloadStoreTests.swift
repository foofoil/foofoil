import Foundation
import Testing
@testable import foofoil

@MainActor
struct WebDownloadStoreTests {
    @Test func keepsDownloadsInsideDirectory() {
        let directory = URL(fileURLWithPath: "/tmp/foofoil-download-tests", isDirectory: true)
        #expect(WebDownloadStore.destination(for: "../../report.pdf", in: directory, reserved: []).path == directory.appendingPathComponent("report.pdf").path)
        for name in ["", ".", ".."] {
            #expect(WebDownloadStore.destination(for: name, in: directory, reserved: []).lastPathComponent == "download")
        }
    }

    @Test func avoidsExistingAndConcurrentDownloads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("report.pdf"))
        let reserved = directory.appendingPathComponent("report (1).pdf")
        #expect(WebDownloadStore.destination(for: "report.pdf", in: directory, reserved: [reserved]).lastPathComponent == "report (2).pdf")
        #expect(WebDownloadStore.destination(for: "README", in: directory, reserved: [directory.appendingPathComponent("README")]).lastPathComponent == "README (1)")
    }
}
