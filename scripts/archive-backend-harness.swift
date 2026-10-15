import Foundation

@main struct Harness {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { ArchiveReader.recognizes($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        print("library=" + String(cString: archive_version_string()))
        for url in urls {
            let start = Date()
            var result = ""
            do {
                let password: String? = (url.lastPathComponent == "zipcrypto.zip" || url.lastPathComponent.hasPrefix("own-aes")) ? "archive-test" : url.lastPathComponent.contains("winzip_aes") ? "password" : "12345678"
                let index = try ArchiveReader.scan(urls: [url], password: password)
                guard Set(index.entries.map(\.id)).count == index.entries.count else { throw ArchiveFailure.conflict }
                let destination = directory.appendingPathComponent("output-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: destination) }
                do {
                    let skipped = try ArchiveReader.extract(urls: [url], index: index, entries: index.entries, root: destination, basePath: "", password: password, limit: 512 * 1024 * 1024)
                    result = "list=\(index.entries.count) extract=OK skipped=\(skipped) format=\(index.format)"
                } catch { result = "list=\(index.entries.count) extract=FAIL \(error) format=\(index.format)" }
            } catch { result = "list=FAIL \(error)" }
            print("\(url.lastPathComponent)\t\(result)\t\(String(format: "%.3f", Date().timeIntervalSince(start)))s")
        }
    }
}
