import AppKit
import Combine
import OSLog

/// AppKit 全局监听不转发 Mac Mouse Fix 的 Quartz 手势，后台捏合改用只读事件 tap。
/// 所有箔共用一个 tap，只订阅手势，不监听按键，也不拦截或重新投递事件。
@MainActor
final class BackgroundMagnificationMonitor: ObservableObject {
    static let shared = BackgroundMagnificationMonitor()
    @Published private(set) var hasAccess = CGPreflightListenEventAccess()
    @Published private(set) var isListening = false
    private var observers: [UUID: (NSEvent) -> Void] = [:]
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var activationObserver: AnyCancellable?
    private let logger = Logger(subsystem: "com.markonce.foofoil", category: "BackgroundMagnification")

    private init() {
        activationObserver = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
    }

    func observe(_ handler: @escaping (NSEvent) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        refresh()
        return token
    }

    func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
        if observers.isEmpty { stop() }
    }

    /// 仅从用户点击设置按钮的路径请求权限；启动或悬停不会弹出授权提示。
    func requestAccess() {
        _ = CGRequestListenEventAccess()
        refresh()
        if !hasAccess {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
    }

    func refresh() {
        hasAccess = CGPreflightListenEventAccess()
        guard hasAccess, !observers.isEmpty else {
            stop()
            return
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            isListening = CGEvent.tapIsEnabled(tap: tap)
            return
        }
        // MMF 把 CG gesture(29) 封包转换成 NSEvent magnify(30)；不读取其私有字段。
        let mask = (CGEventMask(1) << NSEvent.EventType.gesture.rawValue)
            | (CGEventMask(1) << NSEvent.EventType.magnify.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                MainActor.assumeIsolated {
                    let monitor = Unmanaged<BackgroundMagnificationMonitor>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        monitor.refresh()
                    } else if !NSApp.isActive,
                              event.getIntegerValueField(.eventTargetUnixProcessID) != Int64(ProcessInfo.processInfo.processIdentifier),
                              let converted = NSEvent(cgEvent: event), converted.type == .magnify {
                        // 迅速退出系统回调；布局与落盘在主队列中完成，避免 tap 超时。
                        DispatchQueue.main.async { [weak monitor] in
                            guard let monitor, !NSApp.isActive else { return }
                            for handler in monitor.observers.values { handler(converted) }
                        }
                    }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: context
        ), let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            logger.error("Cannot create background magnification event tap")
            return
        }
        tap = newTap
        source = newSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        isListening = CGEvent.tapIsEnabled(tap: newTap)
        logger.debug("Background magnification tap enabled: \(self.isListening)")
    }

    private func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
        isListening = false
    }
}
