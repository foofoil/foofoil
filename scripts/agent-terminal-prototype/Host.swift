import AppKit
import CryptoKit
import Carbon

@MainActor
final class ProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 在 AppKit 的普通文档打开分派之前识别控制信封，普通打开流程会主动解除隐藏。
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(receiveEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass),
                                                     andEventID: AEEventID(kAEOpenDocuments))
    }

    @objc private func receiveEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return }
        let urls = (0..<list.numberOfItems).compactMap { list.atIndex($0 + 1)?.fileURLValue }
        receive(urls)
    }
    private var source: URL?
    private var scoped = false
    private var bookmark: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentTerminalProbe", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("source.bookmark")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        receive(filenames.map { URL(fileURLWithPath: $0) })
    }

    func application(_ application: NSApplication, open urls: [URL]) { receive(urls) }

    private func releaseSource() {
        if scoped { source?.stopAccessingSecurityScopedResource() }
        source = nil
        scoped = false
    }

    private func receive(_ urls: [URL]) {
        // 同一批次里只有显式交付的原文件可被 acquire 接管；绝不按请求路径扩大授权。
        let delivered = urls.filter { $0.pathExtension != "foilprobe" }
        for envelope in urls where envelope.pathExtension == "foilprobe" {
            let envelopeScoped = envelope.startAccessingSecurityScopedResource()
            defer { if envelopeScoped { envelope.stopAccessingSecurityScopedResource() } }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: envelope.path)
                guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 16_384 else { continue }
                let request = try JSONDecoder().decode(ProbeRequest.self, from: Data(contentsOf: envelope))
                var response = ProbeResponse(id: request.id, action: request.action, ok: false,
                                             hidden: NSApp.isHidden, windows: NSApp.windows.count,
                                             process: ProcessInfo.processInfo.processIdentifier)
                do {
                    switch request.action {
                    case "acquire":
                        guard let path = request.path,
                              let url = delivered.first(where: { $0.path == path }) else {
                            throw CocoaError(.fileReadNoPermission)
                        }
                        releaseSource()
                        source = url
                        scoped = url.startAccessingSecurityScopedResource()
                        response.scopeStarted = scoped
                        // 书签只存授权元数据，不保存源正文；下次进程可单独尝试恢复。
                        let data = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                        includingResourceValuesForKeys: nil, relativeTo: nil)
                        try data.write(to: bookmark, options: .atomic)
                        response.bookmarkCreated = true
                        try read(url, into: &response)
                    case "read":
                        guard let source else { throw CocoaError(.fileNoSuchFile) }
                        try read(source, into: &response)
                    case "path-only":
                        guard let path = request.path else { throw CocoaError(.fileNoSuchFile) }
                        try read(URL(fileURLWithPath: path), into: &response)
                    case "restore":
                        releaseSource()
                        var stale = false
                        let url = try URL(resolvingBookmarkData: Data(contentsOf: bookmark),
                                          options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                                          bookmarkDataIsStale: &stale)
                        source = url
                        scoped = url.startAccessingSecurityScopedResource()
                        response.scopeStarted = scoped
                        try read(url, into: &response)
                    case "release": releaseSource()
                    case "hide": NSApp.hide(nil)
                    case "status", "quit": break
                    case "reset":
                        releaseSource()
                        if FileManager.default.fileExists(atPath: bookmark.path) {
                            try FileManager.default.removeItem(at: bookmark)
                        }
                    default: throw CocoaError(.featureUnsupported)
                    }
                    response.ok = true
                } catch {
                    response.errorDomain = (error as NSError).domain
                    response.errorCode = (error as NSError).code
                }
                response.hidden = NSApp.isHidden
                response.windows = NSApp.windows.count
                // 文件交付只授权信封本身，原位写回避免依赖父目录写权限。
                let handle = try FileHandle(forWritingTo: envelope)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: JSONEncoder().encode(response))
                try handle.synchronize()
                if request.action == "quit" {
                    releaseSource()
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
            } catch {
                // 不输出请求正文、路径或未来可能加入的凭证。
                NSLog("AgentTerminalProbe envelope failure: %@/%ld", (error as NSError).domain, (error as NSError).code)
            }
        }
    }

    private func read(_ url: URL, into response: inout ProbeResponse) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
        response.bytes = data.count
        response.digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@main
struct ProbeHost {
    static func main() {
        let app = NSApplication.shared
        let delegate = ProbeDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
