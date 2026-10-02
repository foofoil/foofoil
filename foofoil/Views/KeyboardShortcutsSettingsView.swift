//  KeyboardShortcutsSettingsView.swift
//  foofoil
//
//  Created by tolg on 2026/9/15.
//

import SwiftUI

/// 快捷键配置面板：按分组列出可配置命令，点击右侧控件即可重新录制。
/// 以后新增快捷键只需向 `KeyboardShortcutCatalog` 追加分组，界面自动扩展。
struct KeyboardShortcutsSettingsView: View {
    /// 按名称搜索的关键词。
    @State private var nameQuery = ""
    /// 按快捷键搜索的键位；nil 表示不按快捷键过滤。
    @State private var shortcutQuery: KeyboardShortcut?

    private var isFiltering: Bool {
        !nameQuery.trimmingCharacters(in: .whitespaces).isEmpty || shortcutQuery != nil
    }

    private var searchResults: [KeyboardShortcutSearchResult] {
        KeyboardShortcutCatalog.searchResults(nameQuery: nameQuery, shortcutQuery: shortcutQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(NSLocalizedString("Search Keyboard Shortcuts", comment: ""), text: $nameQuery)
                    .textFieldStyle(.roundedBorder)
                // 按键搜索：录制一个键位，筛出当前使用该快捷键的命令；Delete 清除。
                ShortcutRecorderView(
                    shortcut: shortcutQuery,
                    promptTitle: NSLocalizedString("Search by Keys", comment: ""),
                    helpText: NSLocalizedString("Search Shortcut Recorder Help", comment: ""),
                    cancelClearsShortcut: true
                ) { newValue in
                    shortcutQuery = newValue
                }
                .frame(width: 128)
                // 已录键位时提供显式的取消入口；叉号固定占位，避免布局跳动。
                Button {
                    shortcutQuery = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(NSLocalizedString("Clear Shortcut Search", comment: ""))
                .accessibilityLabel(NSLocalizedString("Clear Shortcut Search", comment: ""))
                .frame(width: 20)
                .opacity(shortcutQuery != nil ? 1 : 0)
                .disabled(shortcutQuery == nil)
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
