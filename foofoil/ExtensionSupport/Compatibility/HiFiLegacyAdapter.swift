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

    static func currentResource(in session: ContentSession, fileList: FileListState? = nil) -> ExtensionResource? {
        ExtensionPlaybackSupport.authorizedResource(in: session, fileList: fileList)
    }

    static func currentURL(in session: ContentSession, fileList: FileListState? = nil) -> URL? {
        currentResource(in: session, fileList: fileList)?.url ?? session.request.primaryFileURL
    }
}
