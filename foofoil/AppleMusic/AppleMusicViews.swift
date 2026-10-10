import SwiftUI
import MusicKit

struct AppleMusicResultRow: View {
    let item: AppleMusicLibraryItem
    var isSelected = false
    var body: some View {
        HStack(spacing: 12) {
            musicArtwork(item.artwork, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).lineLimit(1)
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

@ViewBuilder
private func musicArtwork(_ artwork: Artwork?, size: CGFloat) -> some View {
    if let artwork {
        ArtworkImage(artwork, width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 6))
    } else {
        RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
            .frame(width: size, height: size)
    }
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
    private let categories = ["Music Albums", "Music Songs", "Music Playlists"]
    private var filterIdentity: String { "\(library.authorization)|\(category)|\(query)" }
    private var requestIdentity: String { "\(library.authorization)|\(category)|\(query)|\(page)" }

    var body: some View {
        VStack(spacing: 0) {
            if library.isAuthorized {
                if let selection {
                    detail(selection)
                } else {
                    HStack {
                        Picker("Music Library", selection: $category) {
                            ForEach(categories, id: \.self) { Text(NSLocalizedString($0, comment: "")).tag($0) }
                        }.pickerStyle(.segmented).frame(width: 280)
                        Spacer()
                        TextField("Music Search Library", text: $query).textFieldStyle(.roundedBorder).frame(width: 230)
                    }.padding(18)
                    Divider()
                    ScrollView {
                        if category == "Music Songs" || !query.isEmpty {
                            LazyVStack(spacing: 2) {
                                ForEach(items) { item in
                                    Button { choose(item) } label: { AppleMusicResultRow(item: item) }.buttonStyle(.plain)
                                }
                            }.padding(10)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .top)], alignment: .leading, spacing: 20) {
                                ForEach(items) { item in
                                    Button { choose(item) } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            musicArtwork(item.artwork, size: 145)
                                            Text(item.title).lineLimit(2)
                                            Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }.frame(width: 145, alignment: .leading)
                                    }.buttonStyle(.plain)
                                }
                            }.padding(20)
                        }
                        if hasMore && query.isEmpty {
                            Button("Music Load More") { page += 1 }.disabled(loading).padding()
                        }
                        if !loading && items.isEmpty && error == nil {
                            Text("Music Library Empty").foregroundStyle(.secondary).padding(30)
                        }
                    }
                }
            } else {
                Spacer()
                Image(systemName: "music.note.list").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Music Library").font(.title2).padding(.top, 12)
                Text(library.authorization == .denied || library.authorization == .restricted
                     ? "Music Authorization Denied" : "Music Authorization Message")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                if library.authorization == .notDetermined {
                    Button("Music Authorize") { Task { await library.authorize() } }.buttonStyle(.borderedProminent)
                } else {
                    Button("Music Refresh Authorization") { library.refreshAuthorization() }
                }
                Spacer()
            }
            if loading || detailLoading { ProgressView().controlSize(.small).padding(8) }
            if let error {
                HStack {
                    Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Music Retry") {
                        if selection != nil { detailRevision += 1 }
                        else { offset = 0; library.refreshAuthorization(); page += 1 }
                    }
                }.padding(12)
            }
        }
        .frame(minWidth: 620, minHeight: 440)
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

    private func detail(_ item: AppleMusicLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { selection = nil } label: { Label("Music Back", systemImage: "chevron.left") }
            HStack(spacing: 18) {
                musicArtwork(item.artwork, size: 130)
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).font(.title2).lineLimit(2)
                    Text(item.subtitle).foregroundStyle(.secondary)
                    Button("Music Play") { open(item) }.buttonStyle(.borderedProminent).disabled(detailLoading || tracks.isEmpty)
                }
            }
            List(Array(tracks.enumerated()), id: \.element.id) { index, track in
                Button { open(item, track: track) } label: {
                    HStack {
                        Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 25)
                        Text(track.title)
                        Spacer()
                        if let duration = track.duration { Text(VideoPlayerController.formatPlaybackTime(duration)).foregroundStyle(.secondary) }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(18)
    }

    private func choose(_ item: AppleMusicLibraryItem) {
        if case .song = item { open(item) } else { selection = item }
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
                : try await library.search(query)
            try Task.checkCancellation()
            if append { items += values } else { items = values }
            loadedFilter = filterIdentity
            offset = items.count
            hasMore = values.count == 60
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

@MainActor
final class AppleMusicLibraryWindowController: NSWindowController {
    static let shared = AppleMusicLibraryWindowController()
    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = NSLocalizedString("Music Library", comment: "")
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: AppleMusicLibraryView())
        window.center()
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show() {
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
    @objc func openAppleMusicLibraryAction() { AppleMusicLibraryWindowController.shared.show() }

    func openAppleMusic(_ item: AppleMusicLibraryItem, startingAt track: Track? = nil) {
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
