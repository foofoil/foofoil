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
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var startupBehavior = SettingsStore.shared.startupBehavior
    @State private var navigatorPanelSide = SettingsStore.shared.navigatorPanelSide
    @State private var isFileSearchAuthorized = SpotlightSearchAccess.shared.isAuthorized
    @State private var appleMusicLibraryEnabled = SettingsStore.shared.appleMusicLibraryEnabled
    @State private var appleMusicSearchEnabled = SettingsStore.shared.appleMusicSearchEnabled
    @ObservedObject private var musicLibrary = AppleMusicLibrary.shared

    var body: some View {
        Form {
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
        .formStyle(.grouped)
        .frame(width: SettingsWindowMetrics.width, alignment: .top)
        .onAppear {
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
