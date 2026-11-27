import Foundation
import VideoExtensionRuntime
import FoofoilExtensionKit

let runtime = VideoRuntime()
var failures = 0
for path in CommandLine.arguments.dropFirst() {
    do {
        var session = try runtime.create(.singleFile(.init(url: URL(fileURLWithPath: path))))
        guard case .video(let frame) = session.presentation, frame.surfaceID != 0 else {
            throw ContentProviderError.sessionCreationFailed("Missing video frame")
        }
        session = try runtime.perform(JSONEncoder().encode(MediaPlaybackRequest(action: .setVolume(0), session: session)))
        session = try runtime.perform(JSONEncoder().encode(MediaPlaybackRequest(action: .seek(60), session: session)))
        let commands = session.commands.filter(\.isEnabled)
        for command in commands {
            let data = try JSONSerialization.data(withJSONObject: ["commandID": command.id,
                "session": JSONSerialization.jsonObject(with: JSONEncoder().encode(session))])
            session = try runtime.perform(data)
            guard session.mediaPlayback?.state != .failed else { throw ContentProviderError.sessionCreationFailed("Track decode failed: \(command.id)") }
        }
        session = try runtime.perform(JSONEncoder().encode(MediaPlaybackRequest(action: .play, session: session)))
        Thread.sleep(forTimeInterval: 0.8)
        session = try runtime.perform(JSONEncoder().encode(MediaPlaybackRequest(action: .refresh, session: session)))
        guard session.mediaPlayback?.state == .playing, (session.mediaPlayback?.position ?? 0) > 60.2 else {
            throw ContentProviderError.sessionCreationFailed("Playback clock did not advance: \(String(describing: session.mediaPlayback))")
        }
        session = try runtime.perform(JSONEncoder().encode(MediaPlaybackRequest(action: .pause, session: session)))
        let paused = session.mediaPlayback?.position ?? 0
        Thread.sleep(forTimeInterval: 0.1)
        session = try runtime.perform(JSONEncoder().encode(MediaPlaybackRequest(action: .refresh, session: session)))
        guard abs((session.mediaPlayback?.position ?? 0) - paused) < 0.05 else { throw ContentProviderError.sessionCreationFailed("Pause clock drift") }
        print("OK \(path): \(frame.width)x\(frame.height), \(session.mediaPlayback?.duration ?? 0)s, \(commands.count) tracks; seek/play/pause passed")
        _ = try runtime.perform(JSONEncoder().encode(SessionLifecycleRequest(operation: .close, session: session)))
    } catch { failures += 1; print("FAIL \(path): \(error)") }
}
runtime.shutdown()
if failures > 0 { exit(1) }
