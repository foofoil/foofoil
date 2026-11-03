//
//  ContentTypesSettingsView.swift
//  foofoil
//
//  Created by tolg on 2026/8/27.
//

import SwiftUI

/// 按内容类型分组的设置，包括图片轮播与音视频控制条行为。
/// 设置项说明统一作为标题下的副标题展示，与快捷键面板的行文案保持一致。
struct ContentTypesSettingsView: View {
    @State private var defaultThemeID = SettingsStore.shared.defaultDocumentThemeID
    @State private var defaultFontSize = SettingsStore.shared.defaultDocumentFontSize
    @State private var slideshowInterval = SettingsStore.shared.imageListSlideshowInterval
    @State private var mediaControlsAutoHideInterval = SettingsStore.shared.mediaPlaybackControlsAutoHideInterval
    @State private var mediaSeekStep = SettingsStore.shared.mediaSeekStepInterval
    @State private var showsBottomProgress = SettingsStore.shared.showsMediaBottomProgressBar
    @State private var appleMusicLibraryEnabled = SettingsStore.shared.appleMusicLibraryEnabled
    @AppStorage(SettingsStore.keepAudioPlayingInBackgroundKey) private var keepAudioPlayingInBackground = false
    @State private var confirmClosingPlayingAudio = SettingsStore.shared.confirmClosingPlayingAudio

    var body: some View {
        Form {
            Section {
                Picker("Default Document Theme", selection: $defaultThemeID) {
                    ForEach(DocumentThemeCatalog.shared.presets, id: \.id) { theme in
                        Text(NSLocalizedString(theme.name, comment: "")).tag(theme.id)
                    }
                }
                SettingsSliderRow(title: NSLocalizedString("Default Document Font Size", comment: ""), note: NSLocalizedString("Default Document Style Note", comment: ""), valueLabel: String(Int(defaultFontSize)), value: $defaultFontSize, range: AppState.minTextFontSize...AppState.maxTextFontSize)
            } header: { Text("Default Document Style") }
            Section {
                SettingsSliderRow(
                    title: NSLocalizedString("Slideshow Interval", comment: ""),
                    note: NSLocalizedString("Slideshow Interval Note", comment: ""),
                    valueLabel: slideshowIntervalLabel,
                    value: $slideshowInterval,
                    range: ImageListSlideshow.minInterval...ImageListSlideshow.maxInterval
                )
            } header: {
                Text(NSLocalizedString("Images", comment: ""))
            }
            Section {
                Toggle(isOn: $showsBottomProgress) {
                    SettingsRowLabel(
                        title: NSLocalizedString("Bottom Progress Bar", comment: ""),
                        note: NSLocalizedString("Bottom Progress Bar Note", comment: "")
                    )
                }
                SettingsSliderRow(
                    title: NSLocalizedString("Seek Step", comment: ""),
                    note: NSLocalizedString("Seek Step Note", comment: ""),
                    valueLabel: seekStepLabel,
                    value: $mediaSeekStep,
                    range: MediaSeekStep.minInterval...MediaSeekStep.maxInterval
                )
            } header: {
                Text(NSLocalizedString("Audio and Video", comment: ""))
            }
            Section {
                Toggle(isOn: $keepAudioPlayingInBackground) {
                    SettingsRowLabel(
                        title: NSLocalizedString("Keep Audio Playing in Background", comment: ""),
                        note: NSLocalizedString("Keep Audio Playing in Background Note", comment: "")
                    )
                }
                Toggle(isOn: $confirmClosingPlayingAudio) {
                    SettingsRowLabel(
                        title: NSLocalizedString("Confirm Before Closing Playing Audio", comment: ""),
                        note: NSLocalizedString("Confirm Before Closing Playing Audio Note", comment: "")
                    )
                }
                .disabled(keepAudioPlayingInBackground)
                Toggle(isOn: $appleMusicLibraryEnabled) {
                    SettingsRowLabel(
                        title: NSLocalizedString("Music Enable Library", comment: ""),
                        note: NSLocalizedString("Music Enable Library Note", comment: "")
                    )
                }
            } header: {
                Text(NSLocalizedString("Audio", comment: ""))
            }
            Section {
                SettingsSliderRow(
                    title: NSLocalizedString("Playback Controls Hide Delay", comment: ""),
                    note: NSLocalizedString("Playback Controls Hide Delay Note", comment: ""),
                    valueLabel: mediaControlsIntervalLabel,
                    value: $mediaControlsAutoHideInterval,
                    range: MediaPlaybackControlsAutoHide.minInterval...MediaPlaybackControlsAutoHide.maxInterval
                )
            } header: {
                Text(NSLocalizedString("Video", comment: ""))
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsWindowMetrics.width, alignment: .top)
        .onAppear {
            defaultThemeID = SettingsStore.shared.defaultDocumentThemeID
            defaultFontSize = SettingsStore.shared.defaultDocumentFontSize
            slideshowInterval = SettingsStore.shared.imageListSlideshowInterval
            mediaControlsAutoHideInterval = SettingsStore.shared.mediaPlaybackControlsAutoHideInterval
            mediaSeekStep = SettingsStore.shared.mediaSeekStepInterval
            showsBottomProgress = SettingsStore.shared.showsMediaBottomProgressBar
            appleMusicLibraryEnabled = SettingsStore.shared.appleMusicLibraryEnabled
            confirmClosingPlayingAudio = SettingsStore.shared.confirmClosingPlayingAudio
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentConfigurationDidChange)) { _ in
            defaultThemeID = SettingsStore.shared.defaultDocumentThemeID
            defaultFontSize = SettingsStore.shared.defaultDocumentFontSize
            mediaSeekStep = SettingsStore.shared.mediaSeekStepInterval
            mediaControlsAutoHideInterval = SettingsStore.shared.mediaPlaybackControlsAutoHideInterval
        }
        .onChange(of: defaultThemeID) { _, value in SettingsStore.shared.defaultDocumentThemeID = value }
        .onChange(of: defaultFontSize) { _, value in SettingsStore.shared.defaultDocumentFontSize = value }
        .onChange(of: appleMusicLibraryEnabled) { _, value in
            SettingsStore.shared.appleMusicLibraryEnabled = value
            if value { AppleMusicLibrary.shared.refreshAuthorization() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appleMusicSearchDidChange)) { _ in
            appleMusicLibraryEnabled = SettingsStore.shared.appleMusicLibraryEnabled
        }
        .onChange(of: slideshowInterval) { _, value in
            SettingsStore.shared.imageListSlideshowInterval = value
        }
        .onChange(of: showsBottomProgress) { _, value in
            SettingsStore.shared.showsMediaBottomProgressBar = value
        }
        .onChange(of: confirmClosingPlayingAudio) { _, value in
            SettingsStore.shared.confirmClosingPlayingAudio = value
        }
        .onChange(of: mediaSeekStep) { _, value in
            SettingsStore.shared.mediaSeekStepInterval = value
        }
        .onChange(of: mediaControlsAutoHideInterval) { _, value in
            SettingsStore.shared.mediaPlaybackControlsAutoHideInterval = value
        }
    }

    private var slideshowIntervalLabel: String {
        String(
            format: NSLocalizedString("Slideshow Interval Seconds Format", comment: ""),
            Int(slideshowInterval.rounded())
        )
    }

    private var seekStepLabel: String {
        String(
            format: NSLocalizedString("Seek Step Seconds Format", comment: ""),
            Int(mediaSeekStep.rounded())
        )
    }

    private var mediaControlsIntervalLabel: String {
        String(
            format: NSLocalizedString("Playback Controls Hide Delay Seconds Format", comment: ""),
            Int(mediaControlsAutoHideInterval.rounded())
        )
    }
}

/// 标题 + 副标题的说明样式：说明改用短句紧贴标题，替代分组底部的长段落。
struct SettingsRowLabel: View {
    let title: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 带副标题说明的滑杆设置行；数值标签靠右，滑杆与说明左对齐，保持分组内各行整齐。
private struct SettingsSliderRow: View {
    let title: String
    let note: String
    let valueLabel: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SettingsRowLabel(title: title, note: note)
                Spacer(minLength: 8)
                Text(valueLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            // 不传 step：避免 macOS 滑杆显示刻度线；仍用取整绑定保持秒数为整数。
            Slider(value: integerValue, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(valueLabel)
        }
    }

    private var integerValue: Binding<Double> {
        Binding(
            get: { value },
            set: { value = $0.rounded() }
        )
    }
}
