import Foundation
import FoofoilExtensionKit

/// 旧版 Hi-Fi JSON 协议的宿主适配。通用契约上线后逐项删除，不作为新的公共 API。
enum HiFiLegacyAdapter {
    static let extensionID = "app.foofoil.extension.hifi"
    static let providerID = "audio.hifi"
    static let playbackQueueID = "hifi.playback-queue"

    enum Command: String {
        case play = "hifi.play"
        case pause = "hifi.pause"
        case seek = "hifi.seek"
        case previous = "hifi.previous"
        case next = "hifi.next"
        case status = "hifi.status"
        case close = "hifi.close"
        case activate = "hifi.navigator.activate"
        case move = "hifi.navigator.move"
    }

    static func supports(_ session: ContentSession?) -> Bool {
        session?.providerID == providerID
    }

    static func commandID(for action: ExtensionMediaAction) -> String {
        switch action {
        case .play: Command.play.rawValue
        case .pause: Command.pause.rawValue
        case .previous: Command.previous.rawValue
        case .next: Command.next.rawValue
        case .refresh: Command.status.rawValue
        case .seek: Command.seek.rawValue
        case .selectDevice(let id): deviceCommand(id)
        }
    }

    static func isDeviceEnabled(_ deviceID: String, in session: ContentSession) -> Bool {
        session.commands.first(where: { $0.id == deviceCommand(deviceID) })?.isEnabled == true
    }

    static func deviceCommand(_ deviceID: String) -> String {
        "hifi.device.\(deviceID)"
    }

    static func deviceID(in commandID: String) -> String? {
        let prefix = "hifi.device."
        guard commandID.hasPrefix(prefix) else { return nil }
        return String(commandID.dropFirst(prefix.count))
    }

    /// 旧协议把源文件序号编码在曲目 ID 中；该约定不应进入通用呈现代码。
    static func currentResource(in session: ContentSession) -> ExtensionResource? {
        let resources = session.request.resources
        guard let queue = session.playbackQueue,
              let currentID = queue.currentItemID else {
            return resources.first
        }
        let sourceIndex = currentID.hasPrefix("file:")
            ? Int(currentID.dropFirst("file:".count))
            : queue.items.firstIndex(where: { $0.id == currentID })
        guard let index = sourceIndex, resources.indices.contains(index) else {
            return resources.first
        }
        return resources[index]
    }

    static func currentURL(in session: ContentSession) -> URL? {
        currentResource(in: session)?.url ?? session.request.primaryFileURL
    }

    /// 旧协议把外部文件编码为 `file:{resourceIndex}`；通用路径不得复用该前缀。
    static func legacyQueueItemID(for item: FileListItem, in session: ContentSession) -> String? {
        guard supports(session), item.cue == nil,
              let index = session.request.resources.firstIndex(where: {
                  $0.url.standardizedFileURL == item.url.standardizedFileURL
              }) else { return nil }
        return "file:\(index)"
    }
}
