import Foundation
import AppKit
import AVFoundation
import Testing
@testable import foofoil

struct CameraFoilTests {
    @Test func cameraKeywordsRequireAvailableDevice() {
        for query in ["摄像", "打开摄像头", "CAMERA", "webcam", "相机"] {
            #expect(CameraCaptureController.matches(query, available: true))
            #expect(!CameraCaptureController.matches(query, available: false))
        }
        #expect(!CameraCaptureController.matches("", available: true))
        #expect(!CameraCaptureController.matches("photo", available: true))
    }

    @MainActor @Test func searchCameraCommandOpensSelectedAndHidesWithoutDevices() {
        let model = HistorySearchViewModel(historySearch: { _ in [] }, fileSearch: { _, done in done(.results([])) }, cameraAvailable: { true })
        var opened = false
        model.openCamera = { opened = true }
        model.query = "摄像"
        #expect(model.itemIDs.first == "camera")
        model.openSelected()
        #expect(opened)
        model.stop()
        let unavailable = HistorySearchViewModel(cameraAvailable: { false })
        unavailable.query = "camera"
        #expect(!unavailable.showsOpenCamera)
        unavailable.stop()
    }

    @MainActor @Test func exposeCameraCommandUsesCameraIcon() {
        let model = FoilExposeModel(items: [], historyItems: [], cameraAvailable: { true })
        model.searchText = "camera"
        #expect(model.currentItems.first?.id == FoilExposeItem.cameraCommandID)
        #expect(model.currentItems.first?.symbolName == "camera")
        #expect(model.currentItems.first?.isNewFoil == false)
        model.stopFileSearch()
        let unavailable = FoilExposeModel(items: [], historyItems: [], cameraAvailable: { false })
        unavailable.searchText = "摄像"
        #expect(unavailable.currentItems.isEmpty)
        unavailable.stopFileSearch()
    }

    @Test func cameraConfigurationRoundTripsAsCamera() throws {
        let config = WindowConfig(id: UUID(), imagePath: "/tmp/frame.png", isCamera: true)
        let decoded = try JSONDecoder().decode(WindowConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.isCamera)
        #expect(HistoryContentKind.infer(from: decoded) == .camera)
        #expect(decoded.historyMenuSymbolName == "camera")
        #expect(!HistoryContentKind.camera.storesIndexedText)
    }
    @MainActor @Test(arguments: [true, false])
    func cameraWindowUsesImageLayout(bordered: Bool) async throws {
        let state = AppState()
        state.isCamera = true
        state.showBorder = bordered
        let camera = CameraCaptureController()
        state.cameraController = camera
        let controller = FloatingWindowController(appState: state)
        let window = try #require(controller.window)
        defer {
            controller.close()
            state.stopCamera()
            HistoryManager.shared.removeFromHistory(state.toConfig())
        }
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        camera.acceptFrame(try #require(buffer))
        try await Task.sleep(for: .milliseconds(400))
        #expect(state.usesImagePresentation)
        #expect(camera.frameSize == NSSize(width: 1280, height: 720))
        let inset: CGFloat = bordered ? 24 : 0
        #expect(abs((window.frame.width - inset) / (window.frame.height - inset) - 1280.0 / 720) < 0.01)
        if bordered {
            window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY, width: 500, height: 400), display: false)
            controller.fitImageToWindowWidth(animated: false)
            #expect(abs((window.frame.width - 24) / (window.frame.height - 24) - 1280.0 / 720) < 0.01)
        } else {
            #expect(window.minSize == NSSize(width: 80, height: 80))
            controller.beginManualLiveResize()
            let constrained = controller.constrainedManualResizeSize(NSSize(width: 550, height: 300), from: window.frame.size)
            #expect(abs(constrained.width / constrained.height - 1280.0 / 720) < 0.01)
            controller.endManualLiveResize()
        }
        let original = window.frame
        camera.acceptFrame(try #require(buffer))
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.frame == original)
    }

    @MainActor @Test func cameraSnapshotCacheDoesNotEnableExtraction() throws {
        let state = AppState()
        state.isCamera = true
        state.imageURL = try #require(state.getCachedImageURL(extension: "png"))
        state.hasExtractableImageText = true
        state.hasExtractableImageSubject = true
        #expect(!state.canExtractTextFromImage)
        #expect(!state.canExtractImageText)
        #expect(!state.canExtractImageSubject)
        HistoryManager.shared.removeFromHistory(state.toConfig())
    }

    @MainActor @Test func liveCameraIsNotAnAvailableBlankFoil() {
        let delegate = AppDelegate()
        let state = AppState()
        #expect(delegate.isBlank(state))
        state.isCamera = true
        #expect(!delegate.isBlank(state))
        #expect(!state.isBlank)
    }

}
