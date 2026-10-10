//  KeyboardShortcutsSettingsView.swift
//  foofoil
//
//  Created by tolg on 2026/9/15.
//

import SwiftUI

private extension View {
    /// 与圆角输入框相近的外观，使录制提示和键位文字与输入框位置、高度一致。
    func searchSlotStyle() -> some View {
        self
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
    }
}

/// 快捷键配置面板：按分组列出可配置命令，点击右侧控件即可重新录制。
/// 以后新增快捷键只需向 `KeyboardShortcutCatalog` 追加分组，界面自动扩展。
struct KeyboardShortcutsSettingsView: View {
    /// 按名称搜索的关键词。
    @State private var nameQuery = ""
    /// 按快捷键搜索的键位；nil 表示不按快捷键过滤。
    @State private var shortcutQuery: KeyboardShortcut?
    /// 按键搜索正在录制：左侧输入框让位给录制提示。
    @State private var isRecordingShortcut = false

    private var isFiltering: Bool {
        !nameQuery.trimmingCharacters(in: .whitespaces).isEmpty || shortcutQuery != nil
    }

    private var searchResults: [KeyboardShortcutSearchResult] {
        KeyboardShortcutCatalog.searchResults(nameQuery: nameQuery, shortcutQuery: shortcutQuery)
    }

    /// 搜索栏左侧：录制时为呼吸的录制提示，已选键位时显示键位，否则为名称输入框。
    @ViewBuilder
    private var searchSlot: some View {
        if isRecordingShortcut {
            HStack(spacing: 6) {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
                    .symbolEffect(.breathe, options: .repeating)
                Text(NSLocalizedString("Press Shortcut to Search", comment: ""))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .searchSlotStyle()
        } else if let shortcutQuery {
            Text(shortcutQuery.displayString)
                .frame(maxWidth: .infinity, alignment: .leading)
                .searchSlotStyle()
        } else {
            TextField(NSLocalizedString("Search Keyboard Shortcuts", comment: ""), text: $nameQuery)
                .textFieldStyle(.roundedBorder)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                searchSlot
                // 按键搜索：键盘图标开始录制；录制中或已有键位时变为取消/清除。靠右对齐。
                ShortcutRecorderView(
                    shortcut: shortcutQuery,
                    promptTitle: NSLocalizedString("Search by Keys", comment: ""),
                    helpText: NSLocalizedString("Search Shortcut Recorder Help", comment: ""),
                    cancelClearsShortcut: true,
                    idleSymbolName: "keyboard",
                    onRecordingChange: { isRecordingShortcut = $0 }
                ) { newValue in
                    shortcutQuery = newValue
                }
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Form {
                if isFiltering {
                    if searchResults.isEmpty {
                        Text(NSLocalizedString("No Matching Shortcuts", comment: ""))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(searchResults) { result in
                        Section {
                            ForEach(result.definitions) { definition in
                                KeyboardShortcutRow(definition: definition)
                            }
                        } header: {
                            Text(NSLocalizedString(result.section.titleKey, comment: ""))
                        }
                    }
                } else {
                    ForEach(KeyboardShortcutCatalog.sections) { section in
                        Section {
                            ForEach(section.definitions) { definition in
                                KeyboardShortcutRow(definition: definition)
                            }
                        } header: {
                            Text(NSLocalizedString(section.titleKey, comment: ""))
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        // 过滤期间保持面板理想高度不变：窗口不随搜索结果跳动，
        // 避免打字过程中反复改窗口高度造成的顶部错位（系统设置同样保持窗口不动）。
        // 该面板完整内容本就超过 maxHeight，未过滤时窗口高度同样是 maxHeight。
        .frame(minHeight: isFiltering ? SettingsWindowMetrics.maxHeight : 0, alignment: .top)
        .frame(width: SettingsWindowMetrics.width, alignment: .top)
    }
}

/// 单条快捷键：命令名称 + 录制控件；改动过时提供恢复默认的入口。
private struct KeyboardShortcutRow: View {
    let definition: KeyboardShortcutDefinition

    @State private var shortcut: KeyboardShortcut?
    @State private var isCustomized: Bool

    init(definition: KeyboardShortcutDefinition) {
        self.definition = definition
        _shortcut = State(initialValue: KeyboardShortcutStore.shared.shortcut(for: definition))
        _isCustomized = State(initialValue: KeyboardShortcutStore.shared.isCustomized(definition))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(definition.displayName)
                if let note = definition.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            // 固定录制框宽度并统一靠右对齐，避免行与行之间参差不齐。
            ShortcutRecorderView(shortcut: shortcut) { newValue in
                shortcut = newValue
                KeyboardShortcutStore.shared.setShortcut(newValue, for: definition)
                isCustomized = KeyboardShortcutStore.shared.isCustomized(definition)
            }
            .frame(width: 128)
            // 恢复默认入口始终占位，保证录制框列对齐。
            Button {
                reset()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help(NSLocalizedString("Reset Shortcut", comment: ""))
            .accessibilityLabel(NSLocalizedString("Reset Shortcut", comment: ""))
            .frame(width: 20)
            .opacity(isCustomized ? 1 : 0)
            .disabled(!isCustomized)
        }
    }

    private func reset() {
        let value = definition.defaultShortcut
        shortcut = value
        isCustomized = false
        KeyboardShortcutStore.shared.reset(definition)
    }
}
