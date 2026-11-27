import Foundation
import FoofoilExtensionKit
import FoofoilExtensionABI
import VideoDecoder
import CoreImage
import IOSurface
import ImageIO
import UniformTypeIdentifiers

public final class VideoRuntime: @unchecked Sendable {
    private struct Entry {
        var session: ContentSession
        let decoder: UnsafeMutableRawPointer
        let access: ExtensionResourceAccessScope
    }
    private var entries: [UUID: Entry] = [:]
    private let lock = NSLock()
    public init() {}
    public func create(_ request: ContentRequest) throws -> ContentSession {
        lock.lock(); defer { lock.unlock() }
        guard request.resources.count == 1, let url = request.primaryFileURL,
              url.isFileURL, ["mkv", "avi"].contains(url.pathExtension.lowercased()) else { throw ContentProviderError.unsupportedRequest }
        let access = ExtensionResourceAccessScope(request: request)
        var error: UnsafeMutablePointer<CChar>?
        guard let decoder = fv_open(url.path, &error) else {
            let message = error.map { String(cString: $0) } ?? "Cannot open video"
            fv_free(error); throw ContentProviderError.sessionCreationFailed(message)
        }
        let capabilities = ["media.transport", "session.lifecycle", "session.seekable", "ui.commands"].map {
            NegotiatedCapability(declaration: .init(id: $0, contractVersion: 1, scope: $0 == "ui.commands" ? .presentation : .session), state: .active)
        }
        var session = ContentSession(extensionID: "app.foofoil.extension.video", providerID: "video.files", request: request,
            presentation: .video(.init(surfaceID: 0, width: 0, height: 0, revision: 0)), capabilities: capabilities)
        session = try snapshot(session, decoder: decoder)
        session.thumbnailURL = midpointThumbnail(url: url, duration: session.mediaPlayback?.duration ?? 0)
        entries[session.id] = Entry(session: session, decoder: decoder, access: access)
        return session
    }
    public func perform(_ data: Data) throws -> ContentSession {
        lock.lock(); defer { lock.unlock() }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let command = object?["commandID"] as? String, let s = object?["session"] as? [String: Any],
              let idString = s["id"] as? String, let id = UUID(uuidString: idString), var entry = entries[id] else {
            throw ContentProviderError.unsupportedRequest
        }
        switch command {
        case MediaPlaybackRequest.commandIdentifier:
            let request = try JSONDecoder().decode(MediaPlaybackRequest.self, from: data)
            try request.validate()
            switch request.action {
            case .play: fv_play(entry.decoder)
            case .pause: fv_pause(entry.decoder)
            case .seek(let seconds):
                guard fv_seek(entry.decoder, seconds) != 0 else { throw ContentProviderError.sessionCreationFailed("Video seek failed") }
            case .setSubtitleDelay(let delay): fv_subtitle_delay(entry.decoder, delay)
            case .setVolume(let volume): fv_volume(entry.decoder, Float(volume))
            case .refresh: break
            default: throw ContentProviderError.unsupportedRequest
            }
        case SessionLifecycleRequest.commandIdentifier:
            let request = try JSONDecoder().decode(SessionLifecycleRequest.self, from: data)
            try request.validate()
            if request.operation == .close {
                if let url = entry.session.thumbnailURL { try? FileManager.default.removeItem(at: url) }
                fv_close(entry.decoder); entry.access.stop(); entries.removeValue(forKey: id)
                entry.session.mediaPlayback?.state = .stopped
                entry.session.presentation = .video(.init(surfaceID: 0, width: 0, height: 0, revision: 0))
                return entry.session
            }
            if let seconds = request.restoration?.position, fv_seek(entry.decoder, seconds) == 0 {
                throw ContentProviderError.sessionCreationFailed("Video restoration failed")
            }
        default:
            // 轨道命令必须来自运行时声明，宿主不能凭输入猜测 stream index。
            guard entry.session.commands.contains(where: { $0.id == command && $0.isEnabled }),
                  let index = Int(command.split(separator: ".").last ?? "") else { throw ContentProviderError.unsupportedRequest }
            guard fv_select(entry.decoder, Int32(index)) != 0 else { throw ContentProviderError.unsupportedRequest }
        }
        entry.session = try snapshot(entry.session, decoder: entry.decoder)
        entries[id] = entry
        return entry.session
    }
    public func shutdown() {
        lock.lock(); defer { lock.unlock() }
        for entry in entries.values {
            if let url = entry.session.thumbnailURL { try? FileManager.default.removeItem(at: url) }
            fv_close(entry.decoder); entry.access.stop()
        }
        entries.removeAll()
    }
    /// 用独立解码器取中间画面，缩略图失败不影响播放或播放位置。
    private func midpointThumbnail(url: URL, duration: Double) -> URL? {
        guard duration.isFinite, duration > 0 else { return nil }
        var error: UnsafeMutablePointer<CChar>?
        guard let decoder = fv_open(url.path, &error) else { fv_free(error); return nil }
        defer { fv_close(decoder) }
        guard fv_seek(decoder, duration / 2) != 0,
              let bytes = fv_snapshot(decoder) else { return nil }
        defer { fv_free(bytes) }
        guard let state = try? JSONSerialization.jsonObject(with: Data(String(cString: bytes).utf8)) as? [String: Any],
              let id = (state["surfaceID"] as? NSNumber)?.uint32Value,
              let surface = IOSurfaceLookup(id) else { return nil }
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let source = CIImage(ioSurface: surface)
        let scale = min(1, 512 / max(source.extent.width, source.extent.height))
        let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = CIContext(options: [.cacheIntermediates: false]).createCGImage(small, from: small.extent) else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("foofoil-video-thumbnails", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch { return nil }
        let destination = directory.appendingPathComponent(UUID().uuidString + ".png")
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { try? FileManager.default.removeItem(at: destination); return nil }
        return destination
    }
    private func snapshot(_ original: ContentSession, decoder: UnsafeMutableRawPointer) throws -> ContentSession {
        guard let bytes = fv_snapshot(decoder) else { throw ContentProviderError.sessionCreationFailed("Cannot read video state") }
        defer { fv_free(bytes) }
        let data = Data(String(cString: bytes).utf8)
        let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var session = original
        let duration = state["duration"] as? Double ?? 0
        let failure = state["failureMessage"] as? String ?? ""
        session.mediaPlayback = .init(state: ExtensionMediaPlaybackState(rawValue: state["state"] as? String ?? "failed") ?? .failed,
            position: min(duration, max(0, state["position"] as? Double ?? 0)), duration: duration,
            isSeekable: duration > 0, volume: state["volume"] as? Double, failureMessage: failure.isEmpty ? nil : failure,
            availableActions: [.play, .pause, .seek, .refresh, .setVolume, .setSubtitleDelay])
        session.presentation = .video(.init(surfaceID: (state["surfaceID"] as? NSNumber)?.uint32Value ?? 0,
            width: state["width"] as? Int ?? 0, height: state["height"] as? Int ?? 0,
            revision: (state["revision"] as? NSNumber)?.uint64Value ?? 0,
            subtitle: (state["subtitle"] as? [String: Any]).flatMap { value in
                guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
                return try? JSONDecoder().decode(VideoSubtitleSnapshot.self, from: data)
            }))
        session.commands = [CommandDescriptor(id: "video.subtitle.-1", titleLocalizationKey: "Subtitles Off", symbolName: "captions.bubble", isChecked: state["selectedSubtitleID"] as? String == "-1")]
        for track in state["tracks"] as? [[String: Any]] ?? [] {
            guard let id = track["id"] as? String, let kind = track["kind"] as? String, let title = track["title"] as? String else { continue }
            session.commands.append(.init(id: "video.\(kind).\(id)", titleLocalizationKey: kind == "audio" ? "Audio Track" : "Subtitle Track",
                displayTitle: title, symbolName: kind == "audio" ? "waveform" : "captions.bubble",
                isEnabled: track["isSupported"] as? Bool ?? false,
                isChecked: state[kind == "audio" ? "selectedAudioID" : "selectedSubtitleID"] as? String == id))
        }
        return session
    }
}
private let runtime = VideoRuntime()
private let createCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<Int>?) -> Int32 = { _, input, length, output, outputLength in
    respond(input, length, output, outputLength) { data in try runtime.create(JSONDecoder().decode(ContentRequest.self, from: data)) }
}
private let commandCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<Int>?) -> Int32 = { _, input, length, output, outputLength in
    respond(input, length, output, outputLength) { try runtime.perform($0) }
}
private func respond(_ input: UnsafePointer<UInt8>?, _ length: Int,
                     _ output: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, _ outputLength: UnsafeMutablePointer<Int>?,
                     action: (Data) throws -> ContentSession) -> Int32 {
    guard let input, length > 0, let output, let outputLength else { return 1 }
    do {
        let data = try JSONEncoder().encode(action(Data(bytes: input, count: length)))
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        data.copyBytes(to: bytes, count: data.count); output.pointee = bytes; outputLength.pointee = data.count
        return 0
    } catch { return 3 }
}
nonisolated(unsafe) private let interface: UnsafeMutablePointer<FoofoilExtensionInterfaceV1> = {
    let p = UnsafeMutablePointer<FoofoilExtensionInterfaceV1>.allocate(capacity: 1)
    p.initialize(to: FoofoilExtensionInterfaceV1(api_version: 1, struct_size: MemoryLayout<FoofoilExtensionInterfaceV1>.size,
        context: nil, create_session: createCallback, perform_command: commandCallback,
        release_bytes: { _, bytes, _ in bytes?.deallocate() }, destroy: { _ in runtime.shutdown() }, perform_application_command: nil))
    return p
}()
@_cdecl("foofoil_extension_create")
public func foofoilExtensionCreate(_ version: UInt32) -> UnsafePointer<FoofoilExtensionInterfaceV1>? {
    version == 1 ? UnsafePointer(interface) : nil
}
