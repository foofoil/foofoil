import Foundation

/// 帧只通过 IOSurface 的数字 ID 共享，不传递 Swift/AppKit 对象。ID 随会话关闭失效，不能用于历史恢复。
public struct VideoPresentationSnapshot: Codable, Equatable, Sendable {
    public var surfaceID: UInt32
    public var width: Int
    public var height: Int
    public var subtitle: VideoSubtitleSnapshot?
    public var revision: UInt64
    public init(surfaceID: UInt32, width: Int, height: Int, revision: UInt64, subtitle: VideoSubtitleSnapshot? = nil) {
        self.surfaceID = surfaceID; self.width = width; self.height = height; self.revision = revision; self.subtitle = subtitle
    }
}

/// 字幕与视频帧分离；文字由宿主排版，图形字幕使用独立透明 IOSurface。
public struct VideoSubtitleSnapshot: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var surfaceID: UInt32?
    public var width: Int?
    public var height: Int?
    public init(start: Double, end: Double, text: String, surfaceID: UInt32? = nil, width: Int? = nil, height: Int? = nil) {
        self.start = start; self.end = end; self.text = text; self.surfaceID = surfaceID; self.width = width; self.height = height
    }
}
