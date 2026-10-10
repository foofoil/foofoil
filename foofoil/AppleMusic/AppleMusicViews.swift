import SwiftUI
import MusicKit

struct AppleMusicResultRow: View {
    let item: AppleMusicLibraryItem
    var isSelected = false
    var body: some View {
        HStack(spacing: 12) {
            musicArtwork(item.artwork, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(NSLocalizedString(item.typeKey, comment: "")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
    }
}

private func musicArtwork(_ artwork: Artwork?, size: CGFloat) -> some View {
    ZStack {
        // 资料库封面由 MusicKit 加载；底层占位覆盖无封面、加载中和加载失败的情况。
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.28, weight: .light))
                    .foregroundStyle(.secondary)
            }
        if let artwork {
            ArtworkImage(artwork, width: size, height: size)
        }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: 6))
}

struct AppleMusicLibraryView: View {
    @ObservedObject private var library = AppleMusicLibrary.shared
    @State private var category = "Music Albums"
    @State private var query = ""
    @State private var items: [AppleMusicLibraryItem] = []
    @State private var selection: AppleMusicLibraryItem?
    @State private var tracks: [Track] = []
    @State private var loading = false
    @State private var detailLoading = false
    @State private var detailRevision = 0
    @State private var error: String?
    @State private var offset = 0
    @State private var hasMore = false
    @State private var page = 0
    @State private var loadedFilter: String?
    private var filterIdentity: String { "\(library.authorization)|\(category)|\(query)" }
    private var requestIdentity: String { "\(library.authorization)|\(category)|\(query)|\(page)" }

    var body: some View {
        Group {
            if library.isAuthorized {
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
                } detail: {
                    libraryContent
                }
                .navigationSplitViewStyle(.balanced)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            } else {
                libraryContent
            }
        }
        .frame(minWidth: 700, minHeight: 480)
        .task(id: requestIdentity) { await load() }
        .task(id: "\(selection?.id ?? "")|\(detailRevision)") {
            tracks = []; error = nil; detailLoading = false
            guard let selection else { return }
            detailLoading = true
            defer { if !Task.isCancelled { detailLoading = false } }
            do {
                let values = try await library.tracks(in: selection)
                if !Task.isCancelled { tracks = values }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    private var libraryContent: some View {
            VStack(spacing: 0) {
                if library.isAuthorized {
                    if let selection {
                        detail(selection)
                    } else {
                        browser
                    }
                } else {
                    authorizationView
                }
                if let error {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                        Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer()
                        Button("Music Retry") {
                            if selection != nil { detailRevision += 1 }
                            else { offset = 0; library.refreshAuthorization(); page += 1 }
                        }
                    }
                    .padding(16)
                    .background(.background.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .ignoresSafeArea(.container, edges: .top)
    }

    private var sidebar: some View {
        List(selection: Binding<String?>(
            get: { category },
            set: { value in
                guard let value else { return }
                category = value
                selection = nil
            }
        )) {
            Section("Music Library") {
                ForEach(AppleMusicSearchCategory.allCases) { entry in
                    Label(LocalizedStringKey(entry.localizationKey), systemImage: entry.symbolName)
                        .tag(entry.localizationKey)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                Text(NSLocalizedString(category, comment: "")).font(.system(size: 25, weight: .bold))
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Music Search Library", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel(Text("Clear"))
                    }
                }
                .padding(9)
                .frame(width: 190)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 20)
            Divider().padding(.horizontal, 24)
            if loading && items.isEmpty {
                Spacer()
                ProgressView().controlSize(.regular)
                Spacer()
            } else if items.isEmpty && error == nil {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: query.isEmpty ? "music.note.list" : "magnifyingglass")
                        .font(.system(size: 36, weight: .light)).foregroundStyle(.tertiary)
                    Text("Music Library Empty").foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    if category == "Music Songs" || !query.isEmpty {
                        LazyVStack(spacing: 4) {
                            ForEach(items) { item in
                                Button { choose(item) } label: { AppleMusicResultRow(item: item) }
                                    .buttonStyle(MusicLibraryRowButtonStyle())
                            }
                        }.padding(16)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20, alignment: .top)],
                                  alignment: .leading, spacing: 24) {
                            ForEach(items) { item in
                                Button { choose(item) } label: { MusicLibraryCard(item: item) }
                                    .buttonStyle(.plain)
                            }
                        }.padding(24)
                    }
                    if hasMore && query.isEmpty {
                        Button("Music Load More") { page += 1 }
                            .buttonStyle(.bordered).disabled(loading).padding(.bottom, 24)
                    }
                    if loading { ProgressView().controlSize(.small).padding(.bottom, 20) }
                }
            }
        }
    }

    private var authorizationView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "music.note")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 96, height: 96)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 24))
            VStack(spacing: 10) {
                Text("Music Library").font(.system(size: 28, weight: .bold))
                Text(library.authorization == .denied || library.authorization == .restricted
                     ? "Music Authorization Denied" : "Music Authorization Message")
                    .font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 360)
            }
            if library.authorization == .notDetermined {
                Button("Music Authorize") { Task { await library.authorize() } }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Button("Music Refresh Authorization") { library.refreshAuthorization() }
                    .buttonStyle(.bordered).controlSize(.large)
            }
            Spacer()
        }.padding(40)
    }

    private func detail(_ item: AppleMusicLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { selection = nil } label: { Label("Music Back", systemImage: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(.secondary).padding(.bottom, 24)
            HStack(alignment: .center, spacing: 24) {
                musicArtwork(item.artwork, size: 160)
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
                VStack(alignment: .leading, spacing: 10) {
                    Text(NSLocalizedString(item.typeKey, comment: "")).font(.caption).foregroundStyle(.secondary)
                    Text(item.displayTitle).font(.system(size: 26, weight: .bold)).lineLimit(3)
                    Text(item.subtitle).foregroundStyle(.secondary).lineLimit(2)
                    Button { open(item) } label: { Label("Music Play", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(detailLoading || tracks.isEmpty).padding(.top, 6)
                }
                Spacer(minLength: 0)
            }.padding(.bottom, 24)
            Divider()
            if detailLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            Button { open(item, track: track) } label: {
                                HStack(spacing: 14) {
                                    Text("\(index + 1)").monospacedDigit().foregroundStyle(.tertiary).frame(width: 26)
                                    Text(track.title).lineLimit(1)
                                    Spacer()
                                    if let duration = track.duration {
                                        Text(VideoPlayerController.formatPlaybackTime(duration))
                                            .monospacedDigit().font(.callout).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 12).padding(.vertical, 12).contentShape(Rectangle())
                            }.buttonStyle(MusicLibraryRowButtonStyle())
                        }
                    }.padding(.top, 12)
                }
            }
        }.padding(24)
    }

    private func choose(_ item: AppleMusicLibraryItem) {
        switch item.content {
        case .song, .album: open(item)
        case .playlist: selection = item
        }
    }
    private func open(_ item: AppleMusicLibraryItem, track: Track? = nil) {
        (NSApp.delegate as? AppDelegate)?.openAppleMusic(item, startingAt: track)
        AppleMusicLibraryWindowController.shared.close()
    }
    private func load() async {
        guard library.isAuthorized else { return }
        let append = loadedFilter == filterIdentity && page > 0 && query.isEmpty && offset > 0
        if !append { items = []; offset = 0 }
        loading = true; error = nil
        defer { if !Task.isCancelled { loading = false } }
        do {
            try await Task.sleep(for: .milliseconds(200))
            let values = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? try await library.browse(category, offset: offset)
                : try await library.search(query, category: category)
            try Task.checkCancellation()
            if append { items += values } else { items = values }
            loadedFilter = filterIdentity
            offset = items.count
            hasMore = values.count == 60
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

private struct MusicLibraryCard: View {
    let item: AppleMusicLibraryItem
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            musicArtwork(item.artwork, size: 150)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                            .padding(10).background(.regularMaterial, in: Circle())
                            .padding(10).opacity(hovering ? 1 : 0)
                    }
                .shadow(color: .black.opacity(hovering ? 0.16 : 0.08), radius: hovering ? 9 : 4, y: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(2)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct MusicLibraryRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.08 : hovering ? 0.04 : 0),
                            in: RoundedRectangle(cornerRadius: 8))
                .onHover { hovering = $0 }
        }
    }
}

@MainActor
private final class AppleMusicLibraryWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        // 搜索框获得焦点时也让 Esc 关闭资料库，而不是只清空输入。
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            performClose(nil)
            return
        }
        // 原生 List 的空白会接收鼠标事件，显式把这部分交给系统窗口拖动。
        if event.type == .leftMouseDown, let contentView {
            var hitView = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil))
            while let view = hitView {
                if let table = view as? NSTableView,
                   table.row(at: table.convert(event.locationInWindow, from: nil)) == -1 {
                    performDrag(with: event)
                    return
                }
                hitView = view.superview
            }
        }
        super.sendEvent(event)
    }
}

@MainActor
final class AppleMusicLibraryWindowController: NSWindowController {
    static let shared = AppleMusicLibraryWindowController()
    private init() {
        let window = AppleMusicLibraryWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = NSLocalizedString("Music Library", comment: "")
        // 让系统侧栏延伸到窗口顶部，隐藏独立标题文字并保留原生窗口按钮。
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .automatic
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.collectionBehavior = [.fullScreenNone]
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: AppleMusicLibraryView())
        // HostingController 安装时会按内容最小尺寸重算窗口，随后设置四列所需的初始宽度。
        window.setContentSize(NSSize(width: 1000, height: 620))
        window.center()
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show() {
        guard SettingsStore.shared.appleMusicLibraryEnabled else { return }
        AppleMusicLibrary.shared.refreshAuthorization()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AppleMusicModeView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var controller = AppleMusicPlaybackController.shared
    @StateObject private var output = SystemAudioOutputController()
    let shouldHideBorder: Bool
    var body: some View {
        AudioPresentationView(appState: appState, controller: controller, info: presentationInfo, shouldHideBorder: shouldHideBorder)
            .overlay(alignment: .topTrailing) { outputDeviceOverlay }
            .onAppear { output.start() }
            .overlay(alignment: .center) {
                if controller.isLoading || (appState.appleMusicItem == nil && appState.appleMusicRestoreError == nil) { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) }
                else if let error = appState.appleMusicRestoreError ?? controller.error {
                    VStack {
                        Text(error).multilineTextAlignment(.center)
                        Button("Music Retry") {
                            Task {
                                await appState.restoreAppleMusicItem()
                                if let item = appState.appleMusicItem { controller.load(item, playbackMode: appState.mediaPlaybackMode) }
                            }
                        }
                    }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding()
                }
            }
            .task(id: "\(appState.id):\(appState.currentMediaRouteGeneration):\(appState.appleMusicReference?.sourceFingerprint ?? "")") {
                guard appState.appleMusicItem == nil else { return }
                await appState.restoreAppleMusicItem()
                guard !Task.isCancelled, let item = appState.appleMusicItem else { return }
                controller.load(item, playbackMode: appState.mediaPlaybackMode)
            }
            .onReceive(controller.$navigator) { contribution in
                let playbackController = controller
                appState.synchronizeAppleMusicNavigator(contribution) { [weak playbackController] in playbackController?.selectEntry(id: $0) }
            }
            .onChange(of: appState.mediaPlaybackMode) {
                controller.applyPlaybackMode(appState.mediaPlaybackMode)
            }
            .onDisappear {
                output.stop()
                appState.isMediaPlaying = false
                let hasMusicWindow = (NSApp.delegate as? AppDelegate)?.windowControllers.contains { $0.appState.appleMusicReference != nil } ?? false
                if !hasMusicWindow { controller.stop() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .shouldToggleVideoPlayback)) { note in
                if note.userInfo?["id"] as? UUID == appState.id { controller.togglePlayPause() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .shouldSeekMediaPlayback)) { note in
                if note.userInfo?["id"] as? UUID == appState.id, let delta = note.userInfo?["delta"] as? Double {
                    controller.adjustTime(by: delta)
                }
            }
            .onReceive(controller.$isPlaying) { appState.isMediaPlaying = $0 }
    }
    private var outputDeviceOverlay: some View {
        VStack(alignment: .trailing, spacing: 6) {
            AppKitPopupMenuButton(title: outputStatus, symbolName: "hifispeaker.2", items: outputMenuItems,
                                  tint: presentationInfo.artwork == nil ? .labelColor : .white)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background {
                    Capsule().fill(presentationInfo.artwork == nil ? Color.primary.opacity(0.08) : .black.opacity(0.45))
                }
            if let error = output.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
        .font(.caption)
        .padding(12)
    }

    private var outputStatus: String {
        guard let device = output.selectedDevice else { return NSLocalizedString("System Audio", comment: "") }
        let details = device.sampleRate.map { "\(device.name) · \(AudioMetadataLoader.formatSampleRate($0))" } ?? device.name
        return String(format: NSLocalizedString("System Audio Status Format", comment: ""), details)
    }

    private var outputMenuItems: [AppKitPopupMenuButton.Item] {
        var items: [AppKitPopupMenuButton.Item] = [
            .command(id: "devices", title: NSLocalizedString("System Output Device", comment: ""), enabled: false) {}
        ]
        items += output.devices.map { device in
            .command(id: device.id, title: device.name, selected: output.selectedID == device.id,
                     enabled: output.canSelectDevice && device.isAvailable) {
                output.selectDevice(id: device.id)
            }
        }
        items += [.separator(), .command(id: "rates", title: NSLocalizedString("Device Sample Rate", comment: ""), enabled: false) {}]
        if let device = output.selectedDevice, !device.rates.isEmpty {
            items += device.rates.map { rate in
                .command(id: "rate-\(rate)", title: AudioMetadataLoader.formatSampleRate(rate),
                         selected: device.sampleRate.map { abs($0 - rate) < 0.5 } ?? false,
                         enabled: device.canSetRate) {
                    output.selectSampleRate(rate, deviceID: device.id)
                }
            }
        } else {
            items.append(.command(id: "unavailable", title: NSLocalizedString("Device Sample Rate Unavailable", comment: ""), enabled: false) {})
        }
        return items
    }

    private var presentationInfo: AudioTrackInfo {
        guard appState.appleMusicItem == nil, let reference = appState.appleMusicReference else { return controller.info }
        var info = AudioTrackInfo.fallback(fileName: reference.title)
        info.artist = reference.subtitle
        return info
    }
}

extension AppDelegate {
    @objc func openAppleMusicLibraryAction() {
        guard SettingsStore.shared.appleMusicLibraryEnabled else { return }
        AppleMusicLibraryWindowController.shared.show()
    }

    @objc func updateAppleMusicAvailability() {
        let enabled = SettingsStore.shared.appleMusicLibraryEnabled
        for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
            menu.items.first { $0.action == #selector(openAppleMusicLibraryAction) }?.isHidden = !enabled
        }
        if !enabled {
            appleMusicLinkTask?.cancel()
            appleMusicLinkTask = nil
            for window in NSApp.windows where window is AppleMusicLibraryWindow { window.orderOut(nil) }
            AppleMusicPlaybackController.stopIfActive()
            for controller in windowControllers.filter({ $0.appState.appleMusicReference != nil }) { controller.close() }
        }
        HistoryManager.shared.refresh()
        updateHistoryMenu()
    }

    /// 快捷键直接打开时按需授权；连续粘贴只允许最后一个请求生效。
    func openAppleMusicLink(_ url: URL) {
        guard SettingsStore.shared.appleMusicLibraryEnabled, let link = AppleMusicLink(url: url) else { return }
        appleMusicLinkTask?.cancel()
        appleMusicLinkTask = Task { @MainActor [weak self] in
            do {
                AppleMusicLibrary.shared.refreshAuthorization()
                if !AppleMusicLibrary.shared.isAuthorized { await AppleMusicLibrary.shared.authorize() }
                try Task.checkCancellation()
                let item = try await AppleMusicLibrary.shared.resolve(link)
                try Task.checkCancellation()
                self?.openAppleMusic(item)
            } catch {
                guard !Task.isCancelled else { return }
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("Music Link Open Failed", comment: "")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    func openAppleMusic(_ item: AppleMusicLibraryItem, startingAt track: Track? = nil) {
        guard SettingsStore.shared.appleMusicLibraryEnabled else { return }
        appleMusicLinkTask?.cancel()
        appleMusicLinkTask = nil
        HistorySearchWindowController.shared.dismiss()
        let existing = windowControllers.first { $0.appState.appleMusicReference != nil } ?? availableBlankWindowController
        let state = existing?.appState ?? AppState()
        state.prepareAppleMusic(item)
        state.saveState()
        AppleMusicHistoryArtwork.schedule(item, historyID: state.id)
        if let existing { existing.window?.makeKeyAndOrderFront(nil) }
        else { showNewWindow(with: state) }
        AppleMusicPlaybackController.shared.load(item, startingAt: track, playbackMode: state.mediaPlaybackMode)
    }
}
