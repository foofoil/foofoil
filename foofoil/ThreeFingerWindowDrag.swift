import AppKit

/// 只处理箔内触摸，不监听其他应用；用触点身份防止换指时窗口跳跃。
struct ThreeFingerWindowDrag {
    struct Contact {
        let identity: AnyHashable
        let position: NSPoint
    }

    private var identities: Set<AnyHashable> = []
    private var initialCenter: NSPoint = .zero
    private var initialOrigin: NSPoint = .zero
    private(set) var isTracking = false
    private(set) var isDragging = false

    /// Quartz 指针坐标向下为正，AppKit 窗口坐标向上为正；位移不依赖主屏幕高度。
    static func cursorPosition(_ cursor: CGPoint, followingWindowFrom previousOrigin: NSPoint,
                               to origin: NSPoint) -> CGPoint {
        CGPoint(x: cursor.x + origin.x - previousOrigin.x,
                y: cursor.y - (origin.y - previousOrigin.y))
    }

    mutating func reset() {
        identities.removeAll()
        isTracking = false
        isDragging = false
    }

    mutating func update(contacts: [Contact], windowOrigin: NSPoint) -> NSPoint? {
        guard contacts.count == 3 else { reset(); return nil }
        let currentIdentities = Set(contacts.map(\.identity))
        guard currentIdentities.count == 3 else { reset(); return nil }
        let center = contacts.reduce(NSPoint.zero) {
            NSPoint(x: $0.x + $1.position.x / 3, y: $0.y + $1.position.y / 3)
        }
        guard isTracking, identities == currentIdentities else {
            identities = currentIdentities
            initialCenter = center
            initialOrigin = windowOrigin
            isTracking = true
            isDragging = false
            return nil
        }
        let dx = center.x - initialCenter.x
        let dy = center.y - initialCenter.y
        // 过滤落指抖动；触摸板物理点映射为屏幕点，留出足够的移动行程。
        guard isDragging || hypot(dx, dy) >= 2 else { return nil }
        isDragging = true
        return NSPoint(x: initialOrigin.x + dx * 3, y: initialOrigin.y + dy * 3)
    }
}
