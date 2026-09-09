import Foundation

/// 宿主内部的媒体意图；当前由旧版适配器编码，尚不是跨扩展的公共契约。
enum ExtensionMediaAction {
    case play
    case pause
    case previous
    case next
    case refresh
    case selectDevice(String)
}

extension AppState {
    func performExtensionMediaAction(_ action: ExtensionMediaAction) {
        performExtensionCommand(HiFiLegacyAdapter.commandID(for: action))
    }
}
