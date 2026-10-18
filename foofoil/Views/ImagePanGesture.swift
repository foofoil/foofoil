import AppKit
import SwiftUI

/// 图片共用原生视口的鼠标锚点缩放；仅在全屏启用拖动平移。
struct ImagePanGesture: NSViewRepresentable {
    var imageSize: NSSize? = nil
    var allowsPanning = true

    func makeNSView(context: Context) -> ImagePanAnchorView { ImagePanAnchorView() }
    func updateNSView(_ view: ImagePanAnchorView, context: Context) {
        view.allowsPanning = allowsPanning
        view.attachToScrollView()
        if let imageSize { view.updateImageSize(imageSize) }
    }
    static func dismantleNSView(_ view: ImagePanAnchorView, coordinator: ()) { view.detach() }
}

final class ImagePanAnchorView: NSView, NSGestureRecognizerDelegate {
    private(set) weak var scrollView: NSScrollView?
    var allowsPanning = true
    private var imageSize: NSSize?
    private var pendingZoom: (relativePoint: NSPoint, viewportPoint: NSPoint)?
    private var zoomScheduled = false
    private var initialOrigin: NSPoint = .zero
    private lazy var pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { detach() }
        else {
            // SwiftUI 装配视图层级后再查找原生滚动容器，兼容 SVG 的 WebKit 子视图。
            DispatchQueue.main.async { [weak self] in self?.attachToScrollView() }
        }
    }

    override func layout() {
        super.layout()
        attachToScrollView()
    }

    func attachToScrollView() {
        guard let enclosingScrollView, enclosingScrollView !== scrollView else { return }
        detach()
        scrollView = enclosingScrollView
        pan.buttonMask = 1
        pan.delegate = self
        pan.delaysPrimaryMouseButtonEvents = false
        enclosingScrollView.contentView.addGestureRecognizer(pan)
    }

    func detach() {
        pan.view?.removeGestureRecognizer(pan)
        scrollView = nil
        pendingZoom = nil
    }

    /// 更新尺寸前保存鼠标下的图像坐标；布局完成后补偿滚动位置，使同一像素留在鼠标下。
    func updateImageSize(_ nextSize: NSSize, pointerInViewport: NSPoint? = nil) {
        defer { imageSize = nextSize }
        guard let previous = imageSize, previous != nextSize,
              previous.width > 0, previous.height > 0, let scrollView else { return }
        let clip = scrollView.contentView
        if pendingZoom == nil {
            let point: NSPoint
            if let pointerInViewport { point = pointerInViewport }
            else if let window {
                let local = clip.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                point = clip.bounds.contains(local)
                    ? NSPoint(x: local.x - clip.bounds.minX, y: local.y - clip.bounds.minY)
                    : NSPoint(x: clip.bounds.width / 2, y: clip.bounds.height / 2)
            } else { point = NSPoint(x: clip.bounds.width / 2, y: clip.bounds.height / 2) }
            let inset = NSPoint(x: max(0, (clip.bounds.width - previous.width) / 2),
                                y: max(0, (clip.bounds.height - previous.height) / 2))
            // 指针位于留白时取最近的图像边缘，避免将留白当作可放大的图片内容。
            pendingZoom = (
                NSPoint(x: min(1, max(0, (clip.bounds.minX + point.x - inset.x) / previous.width)),
                        y: min(1, max(0, (clip.bounds.minY + point.y - inset.y) / previous.height))),
                point
            )
        }
        guard !zoomScheduled else { return }
        zoomScheduled = true
        DispatchQueue.main.async { [weak self] in self?.applyPendingZoom() }
    }

    func applyPendingZoom() {
        zoomScheduled = false
        guard let pendingZoom, let imageSize, let scrollView else { return }
        self.pendingZoom = nil
        window?.contentView?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let inset = NSPoint(x: max(0, (clip.bounds.width - imageSize.width) / 2),
                            y: max(0, (clip.bounds.height - imageSize.height) / 2))
        let proposed = NSRect(origin: NSPoint(
            x: inset.x + pendingZoom.relativePoint.x * imageSize.width - pendingZoom.viewportPoint.x,
            y: inset.y + pendingZoom.relativePoint.y * imageSize.height - pendingZoom.viewportPoint.y
        ), size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard allowsPanning, let scrollView else { return false }
        let clip = scrollView.contentView
        return clip.documentRect.width > clip.bounds.width + 0.5
            || clip.documentRect.height > clip.bounds.height + 0.5
    }

    func beginPan() { initialOrigin = scrollView?.contentView.bounds.origin ?? .zero }

    func pan(by translation: NSPoint) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        let proposed = NSRect(
            origin: NSPoint(x: initialOrigin.x - translation.x, y: initialOrigin.y - translation.y),
            size: clip.bounds.size
        )
        // 使用 NSClipView 的原生边界约束，避免拖出空白；未溢出的轴保持原位。
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
        if recognizer.state == .began { beginPan() }
        if recognizer.state == .began || recognizer.state == .changed,
           let clip = scrollView?.contentView {
            pan(by: recognizer.translation(in: clip))
        }
    }
}
