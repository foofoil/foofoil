import AppKit
import AVFoundation
import Combine
import CoreImage
import SwiftUI

/// 采集和帧转换共用串行队列，预览由系统图层直接显示，不将每帧发布到 SwiftUI。
nonisolated final class CameraCaptureController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.foofoil.camera")
    private let lock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var stopped = false
    private var errorObserver: NSObjectProtocol?
    private var deviceObservers: [NSObjectProtocol] = []
    @MainActor @Published var unavailable = false
    @MainActor @Published private(set) var selectedDeviceID: String?
    @MainActor @Published private(set) var frameSize: NSSize?
    private var lastFrameSize: NSSize?

    override init() {
        super.init()
        // 热插拔后使菜单重新枚举，不把打开箔片时的设备列表固定下来。
        deviceObservers = [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
        errorObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.latestBuffer = nil; self.lock.unlock()
            self.fail()
        }
    }
    deinit {
        for observer in deviceObservers { NotificationCenter.default.removeObserver(observer) }
        if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) }
    }

    static var availableDevices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified).devices.filter { $0.isConnected }
    }
    static var isAvailable: Bool { !availableDevices.isEmpty }
    static func matches(_ query: String, available: Bool = isAvailable) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return available && !text.isEmpty && ["摄像", "相机", "camera", "webcam"].contains { text.contains($0) }
    }
    var hasFrame: Bool { lock.lock(); defer { lock.unlock() }; return latestBuffer != nil }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                if allowed { self?.configure() } else { self?.fail() }
            }
        default: fail()
        }
    }
    private func fail() { DispatchQueue.main.async { [weak self] in self?.unavailable = true } }
    /// 输入切换在采集队列串行完成，保留预览图层和输出；无法接管新设备时恢复原输入。
    func selectDevice(_ deviceID: String) {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        configure(deviceID: deviceID)
    }

    private func configure(deviceID: String? = nil) {
        queue.async { [self] in
            lock.lock(); let cancelled = stopped; lock.unlock()
            guard !cancelled else { return }
            let devices = Self.availableDevices
            let device = deviceID.flatMap { id in devices.first { $0.uniqueID == id } }
                ?? (deviceID == nil ? AVCaptureDevice.default(for: .video) ?? devices.first : nil)
            guard let device, let input = try? AVCaptureDeviceInput(device: device) else {
                if session.inputs.isEmpty { fail() }
                return
            }
            let oldInputs = session.inputs
            if oldInputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.uniqueID == device.uniqueID }) { return }
            session.beginConfiguration()
            session.sessionPreset = .high
            for oldInput in oldInputs { session.removeInput(oldInput) }
            guard session.canAddInput(input) else {
                for oldInput in oldInputs where session.canAddInput(oldInput) { session.addInput(oldInput) }
                session.commitConfiguration()
                if oldInputs.isEmpty { fail() }
                return
            }
            session.addInput(input)
            if session.outputs.isEmpty {
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                guard session.canAddOutput(output) else { session.commitConfiguration(); fail(); return }
                session.addOutput(output)
            }
            lock.lock()
            latestBuffer = nil
            lastFrameSize = nil
            lock.unlock()
            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                self?.selectedDeviceID = device.uniqueID
                self?.unavailable = false
            }
            if !session.isRunning { session.startRunning() }
            if !session.isRunning { fail() }
        }
    }
    func stop() {
        lock.lock(); stopped = true; latestBuffer = nil; lock.unlock()
        queue.async { [self] in
            session.stopRunning()
            for output in session.outputs {
                (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
                session.removeOutput(output)
            }
            for input in session.inputs { session.removeInput(input) }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        acceptFrame(buffer)
    }

    func acceptFrame(_ buffer: CVPixelBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        latestBuffer = buffer
        let size = NSSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        // 只在首帧或分辨率改变时发布尺寸，避免每帧触发 SwiftUI 和窗口布局。
        if size != lastFrameSize {
            lastFrameSize = size
            DispatchQueue.main.async { [weak self] in self?.frameSize = size }
        }
    }
    /// 图像转换在采集队列完成；回调回到主线程操作箔窗与保存面板。
    func capture(_ completion: @escaping (NSImage?) -> Void) {
        queue.async { [self] in
            let image = snapshot()
            DispatchQueue.main.async { completion(image) }
        }
    }

    func snapshot() -> NSImage? {
        lock.lock(); let buffer = latestBuffer; lock.unlock()
        guard let buffer else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: image.extent.size)
    }
}

/// 菜单每次打开时枚举设备；单设备也保留列表和当前选择的原生勾选状态。
struct CameraDeviceContextMenu: View {
    @ObservedObject var controller: CameraCaptureController
    var body: some View {
        Section(NSLocalizedString("Camera Devices", comment: "")) {
            ForEach(CameraCaptureController.availableDevices, id: \.uniqueID) { device in
                Toggle(device.localizedName, isOn: Binding(
                    get: { controller.selectedDeviceID == device.uniqueID },
                    set: { selected in if selected { controller.selectDevice(device.uniqueID) } }
                ))
            }
        }
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let fillsWindow: Bool
    func makeNSView(context: Context) -> NSView {
        let view = PreviewView()
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = fillsWindow ? .resizeAspectFill : .resizeAspect
        view.layer = preview
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.layer as? AVCaptureVideoPreviewLayer)?.videoGravity = fillsWindow ? .resizeAspectFill : .resizeAspect
    }
    private class PreviewView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

struct CameraModeView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var controller: CameraCaptureController
    let shouldHideBorder: Bool

    var body: some View {
        Group {
            if controller.unavailable {
                ContentUnavailableView(NSLocalizedString("Camera Unavailable", comment: ""), systemImage: "camera",
                    description: Text(NSLocalizedString("Camera Access Message", comment: "")))
            } else if shouldHideBorder {
                preview(fillsWindow: !appState.isFullScreen)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
            } else {
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    preview(fillsWindow: false)
                        .frame(width: controller.frameSize.map { $0.width * appState.imageScale },
                               height: controller.frameSize.map { $0.height * appState.imageScale })
                        .transaction { $0.animation = nil }
                }
                .padding(8)
            }
        }
    }

    private func preview(fillsWindow: Bool) -> some View {
        CameraPreview(session: controller.session, fillsWindow: fillsWindow)
            .background(Color.black)
            // 原生预览只绘制画面，输入交给外层与图片相同的拖拽、双击及滚动手势。
            .allowsHitTesting(false)
    }
}

extension AppState {
    func openCamera() {
        stopCamera()
        isCamera = true
        originalImageName = NSLocalizedString("Camera Foil", comment: "") + ".png"
        let controller = CameraCaptureController()
        cameraController = controller
        controller.start()
    }
    func stopCamera() {
        cameraController?.stop()
        cameraController = nil
        isCamera = false
    }
}

extension AppDelegate {
    @objc func openCameraAction() {
        guard CameraCaptureController.isAvailable else { return }
        // 与打开网址一致，优先接管空箔；摄像头已有画面时不会被当作空箔替换。
        if let controller = availableBlankWindowController {
            controller.appState.showBorder = false
            controller.appState.openCamera()
            activateWindow(controller)
        } else {
            let state = AppState()
            state.showBorder = false
            state.openCamera()
            showNewWindow(with: state)
        }
        HistorySearchWindowController.shared.dismiss()
    }
}
