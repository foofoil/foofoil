import AppKit
import Carbon

@MainActor
private final class LaunchResult {
    var completed = false
    var error: Error?
}

@MainActor
@main
struct ProbeClient {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2 else {
            fputs("Usage: probe-client APP ACTION [FILE]\n", stderr)
            exit(2)
        }
        do {
            let request = ProbeRequest(id: UUID(), action: arguments[1],
                                       path: arguments.count > 2 ? URL(fileURLWithPath: arguments[2]).standardizedFileURL.path : nil)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("foil-probe-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let envelope = root.appendingPathComponent("request.foiltermprobe")
            try JSONEncoder().encode(request).write(to: envelope)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envelope.path)
            var urls = [envelope]
            if ["acquire", "grant"].contains(request.action), let path = request.path { urls.insert(URL(fileURLWithPath: path), at: 0) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            let applicationURL = URL(fileURLWithPath: arguments[0])
            configuration.hides = NSWorkspace.shared.runningApplications.first {
                $0.bundleURL?.resolvingSymlinksInPath().path == applicationURL.resolvingSymlinksInPath().path
            }?.isHidden == true
            let frontBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            let launch = LaunchResult()
            if let running = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleURL?.resolvingSymlinksInPath().path == applicationURL.resolvingSymlinksInPath().path
            }) {
                // 标准打开文档事件由系统附带沙盒能力，避免 LaunchServices 的解除隐藏副作用。
                let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                                                   eventID: AEEventID(kAEOpenDocuments),
                                                   targetDescriptor: NSAppleEventDescriptor(processIdentifier: running.processIdentifier),
                                                   returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
                let list = NSAppleEventDescriptor.list()
                for (index, url) in urls.enumerated() { list.insert(NSAppleEventDescriptor(fileURL: url), at: index + 1) }
                event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
                _ = try event.sendEvent(options: [.noReply, .neverInteract], timeout: 5)
                launch.completed = true
            } else {
                NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: configuration) { _, error in
                    DispatchQueue.main.async {
                        launch.error = error
                        launch.completed = true
                    }
                }
            }
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                if launch.completed, let error = launch.error { throw error }
                if let data = try? Data(contentsOf: envelope),
                   let response = try? JSONDecoder().decode(ProbeResponse.self, from: data), response.id == request.id {
                    var output = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                    // 等待本次 LaunchServices 事件的后续 hide/unhide，避免只观察处理回调的一瞬间。
                    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                    output["frontBefore"] = frontBefore
                    output["frontAfter"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
                    output["requestedHidden"] = configuration.hides
                    output["hiddenAfter"] = NSRunningApplication(processIdentifier: response.process)?.isHidden ?? false
                    print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
                    exit(response.ok ? 0 : 1)
                }
            }
            fputs("TIMEOUT: launch or reply not confirmed; do not infer non-execution\n", stderr)
            exit(3)
        } catch {
            fputs("PROBE_FAILED: \((error as NSError).domain)/\((error as NSError).code)\n", stderr)
            exit(1)
        }
    }
}
