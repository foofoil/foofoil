//  NavigatorPanelController.swift
//  foofoil
//
//  Created by tolg on 2026/8/26.

import AppKit
import QuartzCore
import SwiftUI
import FoofoilExtensionKit

final class NavigatorPanel: NSPanel {
    var onDeleteSelected: (() -> Void)?
    var handleKeyDown: ((NSEvent) -> Bool)?
    /// 与导航栏宽度手柄同侧：左挂为左缘，右挂为右缘。
    var widthResizeOnLeadingEdge = true

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           let controller = parent?.windowController as? FloatingWindowController {
            controller.handleNavigatorCommandScroll(event)
            return
        }
        if event.type == .leftMouseDown, shouldDragAttachedFoofoil(with: event) {
            dragAttachedFoofoil(with: event)
            return
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if handleKeyDown?(event) == true { return }
        if event.keyCode == 51 || event.keyCode == 117 {
            onDeleteSelected?()
            return
        }
        super.keyDown(with: event)
    }

    private var isParentFullScreen: Bool {
        (parent?.windowController as? FloatingWindowController)?.appState.isFullScreen == true
    }

    private func shouldDragAttachedFoofoil(with event: NSEvent) -> Bool {
        guard parent != nil, !isParentFullScreen else { return false }
        let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        let onResizeHandle = NavigatorPanelMetrics.containsWidthResizeHandle(
            x: event.locationInWindow.x,
            width: frame.width,
            draggingLeftEdge: widthResizeOnLeadingEdge
        )
        let hit = contentView?.hitTest(event.locationInWindow)
        return Self.shouldDragAttachedFoofoil(
            commandPressed: command,
            onResizeHandle: onResizeHandle,
            hitView: hit
        )
    }

    static func shouldDragAttachedFoofoil(
        commandPressed: Bool,
        onResizeHandle: Bool,
        hitView: NSView?
    ) -> Bool {
        if commandPressed { return true }
        if onResizeHandle { return false }
        guard let hitView else { return true }
        return hitView is ExplicitlyMovableWindowBackground
    }

    /// 拖父窗口，子窗口随相对位置一起走；事件坐标换算到箔片，避免 performDrag 跳一下。
    private func dragAttachedFoofoil(with event: NSEvent) {
        guard let parent else { return }
        parent.makeKeyAndOrderFront(nil)
        let screenPoint = convertPoint(toScreen: event.locationInWindow)
        let parentPoint = parent.convertPoint(fromScreen: screenPoint)
        guard let dragEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: parentPoint,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: parent.windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: event.clickCount,
            pressure: event.pressure
        ) else { return }
        parent.performDrag(with: dragEvent)
    }
}

/// 桌面态使用独立伴随窗口，避免导航面板宽度进入箔片内容 frame 和比例缩放计算。
final class NavigatorPanelController: NSWindowController {
    private let appState: AppState
    private var pendingHide: DispatchWorkItem?
    private var isHiding = false
    private let slideDuration: TimeInterval = 0.25

    init(appState: AppState) {
        self.appState = appState
        let panel = NavigatorPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: appState.navigatorPanelWidth,
                height: 400
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hostingView = NSHostingView(rootView: NavigatorPanelView(appState: appState))
        hostingView.wantsLayer = true
        hostingView.layer?.borderWidth = 0
        hostingView.layer?.borderColor = NSColor.clear.cgColor
        hostingView.layer?.cornerRadius = 12
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        panel.contentView = hostingView
        super.init(window: panel)
        panel.handleKeyDown = { [weak appState] event in
            appState?.handleFileListKeyDown(event) == true
        }
        panel.onDeleteSelected = { [weak appState] in
            guard let appState,
                  let contribution = appState.navigatorContributions.first(where: {
                      $0.id == appState.activeNavigatorContributionID
                  }) ?? appState.navigatorContributions.first,
                  contribution.allowedActions.contains(.remove),
                  !contribution.selectedItemIDs.isEmpty else { return }
            appState.performNavigatorAction(
                NavigatorAction(
                    contributionID: contribution.id,
                    kind: .remove,
                    itemIDs: contribution.selectedItemIDs
                )
            )
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isVisible: Bool { window?.isVisible == true && !isHiding }

    func owns(_ candidate: NSWindow) -> Bool {
        window === candidate
    }

    func show(attachedTo parent: NSWindow) {
        guard let panel = window else { return }
        let needsReveal = !isVisible
        let wasOrderedOut = !panel.isVisible
        pendingHide?.cancel()
        pendingHide = nil
        isHiding = false
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        synchronizeAppearance(with: parent)
        updateFrame(relativeTo: parent)
        panel.orderFront(nil)
        if needsReveal {
            animateSlide(hidden: false, startingHidden: wasOrderedOut)
        }
    }

    func hide(animated: Bool = false) {
        guard let panel = window else { return }
        if animated {
            guard panel.isVisible, !isHiding else { return }
            isHiding = true
            animateSlide(hidden: true)
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isHiding else { return }
                self.window?.orderOut(nil)
                self.pendingHide = nil
                self.isHiding = false
            }
            pendingHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + slideDuration, execute: work)
        } else {
            pendingHide?.cancel()
            pendingHide = nil
            isHiding = false
            panel.contentView?.layer?.removeAnimation(forKey: "navigatorSlide")
            panel.orderOut(nil)
        }
    }

    /// 保持伴随窗口 frame 不变，在窗口裁剪范围内滑动内容；快速反向时从当前呈现位置继续。
    private func animateSlide(hidden: Bool, startingHidden: Bool = false) {
        guard let panel = window, let layer = panel.contentView?.layer else { return }
        let hiddenOffset = panel.frame.width * (appState.navigatorPanelSide == .left ? 1 : -1)
        let currentOffset = startingHidden ? hiddenOffset
            : (layer.presentation()?.transform.m41 ?? layer.transform.m41)
        let targetOffset: CGFloat = hidden ? hiddenOffset : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(targetOffset, 0, 0)
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = currentOffset
        animation.toValue = targetOffset
        animation.duration = slideDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "navigatorSlide")
    }

    func detachAndClose() {
        guard let panel = window else { return }
        hide()
        panel.parent?.removeChildWindow(panel)
        panel.close()
    }

    func synchronizeAppearance(with parent: NSWindow) {
        guard let panel = window else { return }
        panel.level = parent.level
        panel.alphaValue = parent.alphaValue
    }

    func updateFrame(relativeTo parent: NSWindow) {
        guard let panel = window else { return }
        let width = CGFloat(NavigatorPanelMetrics.clampWidth(appState.navigatorPanelWidth))
        let gap = CGFloat(NavigatorPanelMetrics.attachmentGap)
        let x: CGFloat
        switch appState.navigatorPanelSide {
        case .left:
            x = parent.frame.minX - width - gap
        case .right:
            x = parent.frame.maxX + gap
        }
        if let panel = panel as? NavigatorPanel {
            panel.widthResizeOnLeadingEdge = appState.navigatorPanelSide == .left
        }
        let frame = NSRect(x: x, y: parent.frame.minY, width: width, height: parent.frame.height)
        panel.setFrame(frame, display: true)
    }
}
