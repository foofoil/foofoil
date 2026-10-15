import Foundation
@main struct Groups {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let original = try Data(contentsOf: directory.appendingPathComponent("sample.7z"))
        let length = (original.count + 2) / 3
        for n in 0..<3 { try original.subdata(in: n * length..<min((n + 1) * length, original.count)).write(to: directory.appendingPathComponent(String(format: "split.7z.%03d", n + 1))) }
        for prefix in ["split.7z.", "test_read_format_rar_multivolume.part", "test_read_format_rar5_multiarchive.part", "test_read_format_rar5_multiarchive_solid.part"] {
            let all = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(prefix) }.sorted().map { directory.appendingPathComponent($0) }
            for missing in [0, 1, 2] {
                let urls = missing == 0 ? all : missing == 1 ? Array(all.dropLast()) : Array(all.prefix(1))
                do {
                    let index = try ArchiveReader.scan(urls: urls)
                    let out = directory.appendingPathComponent("test-group-\(UUID())")
                    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: out) }
                    let skipped = try ArchiveReader.extract(urls: urls, index: index, entries: index.entries, root: out, basePath: "", password: nil, limit: 512 * 1024 * 1024)
                    print("\(prefix) missing=\(missing) list=\(index.entries.count) extracted skipped=\(skipped)")
                } catch { print("\(prefix) missing=\(missing) FAIL \(error)") }
            }
        }
        _ = names
    }
}
