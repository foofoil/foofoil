//
//  GeneralSettingsView.swift
//  foofoil
//
//  Created by tolg on 2026/9/28.
//

import SwiftUI
import ServiceManagement
import MusicKit

struct GeneralSettingsView: View {
    @ObservedObject private var agentTerminal = (NSApp.delegate as? AppDelegate)?.agentTerminal ?? AgentTerminal()
    @AppStorage("automaticallyRemoveMissingHistory") private var automaticallyRemoveMissingHistory = true
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var startupBehavior = SettingsStore.shared.startupBehavior
    @State private var navigatorPanelSide = SettingsStore.shared.navigatorPanelSide
    @State private var isFileSearchAuthorized = SpotlightSearchAccess.shared.isAuthorized
    @State private var appleMusicLibraryEnabled = SettingsStore.shared.appleMusicLibraryEnabled
    @State private var appleMusicSearchEnabled = SettingsStore.shared.appleMusicSearchEnabled
    @State private var cacheLimitGB = Double(SettingsStore.shared.contentCacheLimitBytes) / 1_073_741_824
    @State private var cacheUsage: Int64 = 0
    @State private var pendingCacheLimit: Int64?
    @State private var showsCacheConfirmation = false
    @State private var cacheError = false
    @State private var updatingCache = false
    @ObservedObject private var backgroundMagnification = BackgroundMagnificationMonitor.shared
    @ObservedObject private var musicLibrary = AppleMusicLibrary.shared

    var body: some View {
        Form {
            Section {
                Toggle("Pause Agent Control", isOn: $agentTerminal.paused)
                Text("Agent Control Note").font(.caption).foregroundStyle(.secondary)
                Button("Revoke Agent Sessions") { agentTerminal.revokeAll() }
            } header: {
                Text("Agent Control")
            }
            Section {
                Toggle(isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        LaunchAtLogin.isEnabled = newValue
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                )) {
                    SettingsRowLabel(
                        title: NSLocalizedString("Launch at Login", comment: ""),
                        note: NSLocalizedString("Launch at Login Note", comment: "")
                    )
                }

                SettingsPickerRow(
                    title: NSLocalizedString("When Launched", comment: ""),
                    note: NSLocalizedString("When Launched Note", comment: "")
                ) {
                    Picker("", selection: $startupBehavior) {
                        ForEach(StartupBehavior.allCases, id: \.self) { behavior in
                            Text(NSLocalizedString(behavior.localizationKey, comment: ""))
                                .tag(behavior)
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("System Section", comment: ""))
            }

            Section {
                HStack {
                    SettingsRowLabel(
                        title: NSLocalizedString("Background Gesture Zoom", comment: ""),
                        note: NSLocalizedString("Background Gesture Zoom Note", comment: "")
                    )
                    Spacer()
                    if backgroundMagnification.hasAccess {
                        Text("Background Gesture Zoom Authorized").foregroundStyle(.secondary)
                    } else {
                        Button("Allow Background Gesture Zoom") { backgroundMagnification.requestAccess() }
                    }
                }
            } header: {
                Text("Window Gestures")
            }

            Section {
                Toggle("Automatically Remove Missing History", isOn: $automaticallyRemoveMissingHistory)
                Text("Missing History Cleanup Note").font(.caption).foregroundStyle(.secondary)
                HStack {
                    SettingsRowLabel(
                        title: NSLocalizedString("Cache Limit", comment: ""),
                        note: String(format: NSLocalizedString("Cache Used: %@", comment: ""), ByteCountFormatter.string(fromByteCount: cacheUsage, countStyle: .binary))
                    )
                    Spacer()
                    TextField("Cache Limit", value: $cacheLimitGB, format: .number)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onSubmit { requestCacheLimit() }
                    Text("GB")
                    Button("Apply") { requestCacheLimit() }
                        .disabled(updatingCache)
                }
                Text("Cache Limit Note").font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Cache Section")
            }

            Section {
                HStack(alignment: .center, spacing: 12) {
                    SettingsRowLabel(
                        title: NSLocalizedString("Share Menu Entry", comment: ""),
                        note: NSLocalizedString(appleMusicLibraryEnabled ? "Share Menu Entry Music Note" : "Share Menu Entry Note", comment: "")
                    )
                    Spacer(minLength: 16)
                    Button("Open Sharing Settings") {
                        // 定位到共享扩展列表；启用开关由用户在系统设置中控制。
                        let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.share-services")!
                        if !NSWorkspace.shared.open(url) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        }
                    }
                    .fixedSize()
                }
            } header: {
                Text(NSLocalizedString("Sharing Section", comment: ""))
            }

            Section {
                SettingsPickerRow(
                    title: NSLocalizedString("Panel Side", comment: ""),
                    note: NSLocalizedString("Panel Side Note", comment: "")
                ) {
                    Picker("", selection: $navigatorPanelSide) {
                        Text(NSLocalizedString("Side Left", comment: "")).tag(NavigatorPanelSide.left)
                        Text(NSLocalizedString("Side Right", comment: "")).tag(NavigatorPanelSide.right)
                    }
                }

            } header: {
                Text(NSLocalizedString("Navigator Section", comment: ""))
            }

            Section {
                Toggle(isOn: Binding(
                    get: { isFileSearchAuthorized },
                    set: { newValue in
                        if newValue {
                            SpotlightSearchAuthorization.request { outcome in
                                DispatchQueue.main.async {
                                    isFileSearchAuthorized = SpotlightSearchAccess.shared.isAuthorized
                                    NotificationCenter.default.post(
                                        name: .spotlightSearchAuthorizationDidChange,
                                        object: nil
                                    )
                                }
                            }
                        } else {
                            SpotlightSearchAccess.shared.clear()
                            isFileSearchAuthorized = false
                            NotificationCenter.default.post(
                                name: .spotlightSearchAuthorizationDidChange,
                                object: nil
                            )
                        }
                    }
                )) {
                    SettingsRowLabel(
                        title: NSLocalizedString("Enable Local Search Index", comment: ""),
                        note: NSLocalizedString("Enable Local Search Index Note", comment: "")
                    )
                }
                if appleMusicLibraryEnabled {
                    Toggle(isOn: $appleMusicSearchEnabled) {
                        SettingsRowLabel(
                            title: NSLocalizedString("Music Enable Search", comment: ""),
                            note: NSLocalizedString("Music Search Settings Note", comment: "")
                        )
                    }
                    if appleMusicSearchEnabled && !musicLibrary.isAuthorized {
                        Button("Music Authorize") { Task { await musicLibrary.authorize() } }
                        if musicLibrary.authorization == .denied || musicLibrary.authorization == .restricted {
                            Text("Music Authorization Denied").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("Search Section", comment: ""))
            }
        }
        .alert("Reduce Cache Limit", isPresented: $showsCacheConfirmation) {
            Button("Cancel", role: .cancel) { restoreCacheLimit() }
            Button("Clear Oldest Cache", role: .destructive) {
                if let limit = pendingCacheLimit { applyCacheLimit(limit, allowClearing: true) }
            }
        } message: {
            Text(String(format: NSLocalizedString("Reduce Cache Limit Message", comment: ""),
                        ByteCountFormatter.string(fromByteCount: cacheUsage, countStyle: .binary),
                        ByteCountFormatter.string(fromByteCount: pendingCacheLimit ?? 0, countStyle: .binary)))
        }
        .alert("Cache Limit Failed", isPresented: $cacheError) {
            Button("OK", role: .cancel) { }
        } message: { Text("Cache Limit Failed Message") }
        .task { await refreshCacheUsage() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ContentCacheDidChange"))) { _ in
            Task { await refreshCacheUsage() }
        }
        .formStyle(.grouped)
        .frame(width: SettingsWindowMetrics.width, alignment: .top)
        .onAppear {
            backgroundMagnification.refresh()
            launchAtLogin = LaunchAtLogin.isEnabled
            startupBehavior = SettingsStore.shared.startupBehavior
            navigatorPanelSide = SettingsStore.shared.navigatorPanelSide
            isFileSearchAuthorized = SpotlightSearchAccess.shared.isAuthorized
            appleMusicLibraryEnabled = SettingsStore.shared.appleMusicLibraryEnabled
            appleMusicSearchEnabled = SettingsStore.shared.appleMusicSearchEnabled
            if appleMusicLibraryEnabled { musicLibrary.refreshAuthorization() }
        }
        .onChange(of: startupBehavior) { _, value in
            SettingsStore.shared.startupBehavior = value
        }
        .onChange(of: navigatorPanelSide) { _, value in
            SettingsStore.shared.navigatorPanelSide = value
        }
        .onChange(of: appleMusicSearchEnabled) { _, value in
            guard appleMusicLibraryEnabled else { return }
            SettingsStore.shared.appleMusicSearchEnabled = value
        }
        .onReceive(NotificationCenter.default.publisher(for: .appleMusicSearchDidChange)) { _ in
            appleMusicLibraryEnabled = SettingsStore.shared.appleMusicLibraryEnabled
            appleMusicSearchEnabled = SettingsStore.shared.appleMusicSearchEnabled
        }
        .onReceive(NotificationCenter.default.publisher(for: .spotlightSearchAuthorizationDidChange)) { _ in
            isFileSearchAuthorized = SpotlightSearchAccess.shared.isAuthorized
        }
    }
    private func restoreCacheLimit() {
        cacheLimitGB = Double(SettingsStore.shared.contentCacheLimitBytes) / 1_073_741_824
        pendingCacheLimit = nil
    }

    private func refreshCacheUsage() async {
        cacheUsage = await Task.detached(priority: .utility) { ContentCache.shared.usage }.value
    }

    private func requestCacheLimit() {
        guard cacheLimitGB.isFinite, cacheLimitGB >= 0.01, cacheLimitGB <= 1_000_000 else {
            restoreCacheLimit()
            cacheError = true
            return
        }
        let limit = Int64(cacheLimitGB * 1_073_741_824)
        updatingCache = true
        Task {
            await refreshCacheUsage()
            updatingCache = false
            if limit < cacheUsage {
                pendingCacheLimit = limit
                showsCacheConfirmation = true
            } else { applyCacheLimit(limit) }
        }
    }

    private func applyCacheLimit(_ limit: Int64, allowClearing: Bool = false) {
        updatingCache = true
        let controllers = (NSApplication.shared.delegate as? AppDelegate)?.windowControllers ?? []
        ContentCache.shared.protect(Set(controllers.map { $0.appState.id }), paths: Set(controllers.flatMap { $0.appState.cachedContentPaths }))
        HistoryManager.shared.flushPendingListSaves()
        Task {
            let outcome = await Task.detached(priority: .utility) {
                do { try ContentCache.shared.setLimit(limit, allowClearing: allowClearing); return 0 }
                catch ContentCache.LimitError.confirmationRequired { return 1 }
                catch { return 2 }
            }.value
            updatingCache = false
            await refreshCacheUsage()
            if outcome == 1 {
                pendingCacheLimit = limit
                showsCacheConfirmation = true
            } else {
                restoreCacheLimit()
                cacheError = outcome == 2
            }
        }
    }
}

/// 带有左侧标题与副标题说明、右侧为固定尺寸选择器控件的行组件。
private struct SettingsPickerRow<Content: View>: View {
    let title: String
    let note: String
    @ViewBuilder let picker: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsRowLabel(title: title, note: note)
            Spacer(minLength: 16)
            picker()
                .labelsHidden()
                .fixedSize()
        }
    }
}
