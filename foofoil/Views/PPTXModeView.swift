import SwiftUI
import Combine
import FoofoilExtensionKit

@MainActor
final class PPTXNavigationController: ObservableObject {
    @Published var slideSize: NSSize?
    @Published var previewURL: URL?
    @Published var currentIndex = 0
    @Published var slides: [PPTXSlide] = []
    @Published var isLoading = true
    @Published var failed = false
    private var requestedIndex = 0
    private var document: PPTXDocument?
    private var sourceURL: URL?
    private var navigationTask: Task<Void, Never>?
    private var generation = UUID()
    private weak var appState: AppState?
    private let contributionID = "pptx.slides.\(UUID())"

    func open(url: URL, appState: AppState) async {
        if sourceURL == url, document != nil { return }
        close()
        sourceURL = url
        self.appState = appState
        let generation = self.generation
        isLoading = true
        failed = false
        do {
            // actor 初始化也须显式离开主线程，避免大型文稿阻塞窗口交互。
            let document = try await Task.detached(priority: .userInitiated) {
                try PPTXDocument(url: url)
            }.value
            guard !Task.isCancelled, generation == self.generation else { return }
            self.document = document
            slideSize = document.slideSize
            slides = document.slides
            select(0)
        } catch {
            guard !Task.isCancelled, generation == self.generation else { return }
            failed = true
            isLoading = false
        }
    }

    func select(_ index: Int) {
        guard slides.indices.contains(index), let document else { return }
        requestedIndex = index
        navigationTask?.cancel()
        generation = UUID()
        let generation = generation
        isLoading = true
        failed = false
        navigationTask = Task { [weak self] in
            do {
                let url = try await document.preview(at: index)
                guard let self, !Task.isCancelled, generation == self.generation else { return }
                self.previewURL = url
                self.currentIndex = index
                self.isLoading = false
                self.publishNavigator()
            } catch {
                guard let self, !Task.isCancelled, generation == self.generation else { return }
                self.requestedIndex = self.currentIndex
                self.failed = true
                self.isLoading = false
            }
        }
    }

    /// 快速连按基于最后请求的页码累加，避免异步预览提交前重复翻到同一页。
    func selectAdjacent(delta: Int) {
        select(requestedIndex + delta)
    }

    private func publishNavigator() {
        guard let appState else { return }
        let items = slides.enumerated().map { index, slide in
            NavigatorItem(
                id: slide.id,
                title: slide.title ?? String(format: NSLocalizedString("PPTX Slide Number", comment: ""), index + 1),
                symbolName: "rectangle.on.rectangle",
                badge: String(index + 1),
                isCurrent: index == currentIndex
            )
        }
        appState.builtInNavigatorContributions = [NavigatorContribution(
            id: contributionID,
            titleLocalizationKey: "PPTX Slides",
            style: .flat,
            items: items,
            selectedItemIDs: [slides[currentIndex].id]
        )]
        appState.activeNavigatorContributionID = contributionID
        appState.builtInNavigatorActionHandler = { [weak self] action in
            guard let self, action.kind == .activate,
                  let id = action.itemIDs.first,
                  let index = self.slides.firstIndex(where: { $0.id == id }) else { return }
            self.select(index)
        }
    }

    func close() {
        generation = UUID()
        navigationTask?.cancel()
        navigationTask = nil
        document = nil
        sourceURL = nil
        previewURL = nil
        slideSize = nil
        slides = []
        currentIndex = 0
        requestedIndex = 0
        if let appState, appState.builtInNavigatorContributions.contains(where: { $0.id == contributionID }) {
            appState.builtInNavigatorContributions = []
            appState.builtInNavigatorActionHandler = nil
            if appState.activeNavigatorContributionID == contributionID { appState.activeNavigatorContributionID = nil }
        }
        appState = nil
    }
}

struct PPTXModeView: View {
    nonisolated static let minimumWindowWidth: CGFloat = 180
    @ObservedObject var appState: AppState
    let url: URL
    @ObservedObject private var controller: PPTXNavigationController

    init(appState: AppState, url: URL) {
        self.appState = appState
        self.url = url
        self.controller = appState.pptxNavigationController
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { proxy in
                let size = Self.fittedSlideSize(in: proxy.size, slide: controller.slideSize)
                Group {
                    if let previewURL = controller.previewURL {
                        PPTXPreviewView(url: previewURL)
                    } else if controller.failed {
                        QuickLookModeView(url: url)
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: size.width, height: size.height)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            WindowDragArea()
            if appState.isMediaPlaybackControlsVisible, !controller.slides.isEmpty {
                pageControls
                    .padding(appState.navigatorPanelSide == .left ? .leading : .trailing,
                             appState.fullScreenNavigatorControlBarInset)
                    .transition(.move(edge: .bottom))
                    .zIndex(1)
            }
            if controller.failed {
                Text(NSLocalizedString("PPTX Navigation Failed", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appState.isFullScreen ? Color.black : Color.clear)
        .clipped()
        .animation(.easeInOut(duration: 0.25), value: appState.isMediaPlaybackControlsVisible)
        .animation(.easeInOut(duration: 0.25), value: appState.fullScreenNavigatorControlBarInset)
        .task(id: url) { await controller.open(url: url, appState: appState) }
    }

    private var pageControls: some View {
        HStack(spacing: 12) {
            Button { controller.selectAdjacent(delta: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .help(NSLocalizedString("PPTX Previous Slide", comment: ""))
            .accessibilityLabel(Text(NSLocalizedString("PPTX Previous Slide", comment: "")))
            .disabled(controller.currentIndex == 0)
            Text(String(format: NSLocalizedString("PPTX Page Count", comment: ""), controller.currentIndex + 1, controller.slides.count))
                .monospacedDigit()
            Button { controller.selectAdjacent(delta: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .help(NSLocalizedString("PPTX Next Slide", comment: ""))
            .accessibilityLabel(Text(NSLocalizedString("PPTX Next Slide", comment: "")))
            .disabled(controller.currentIndex + 1 >= controller.slides.count)
            if controller.isLoading { ProgressView().controlSize(.small) }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .background(NonMovableBackground())
        .padding(8)
    }

    /// 页面适配内容可用区域；目录与控制条不会改变原始页面比例。
    nonisolated static func fittedSlideSize(in available: NSSize, slide: NSSize?) -> NSSize {
        guard let slide, slide.width > 0, slide.height > 0,
              available.width > 0, available.height > 0 else { return available }
        let scale = min(available.width / slide.width, available.height / slide.height)
        return NSSize(width: slide.width * scale, height: slide.height * scale)
    }
}
