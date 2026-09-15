//  KeyboardShortcutsSettingsView.swift
//  foofoil
//
//  Created by tolg on 2026/9/15.
//

import SwiftUI

/// 快捷键配置面板：按分组列出可配置命令，点击右侧控件即可重新录制。
/// 以后新增快捷键只需向 `KeyboardShortcutCatalog` 追加分组，界面自动扩展。
struct KeyboardShortcutsSettingsView: View {
    var body: some View {
        Form {
            ForEach(KeyboardShortcutCatalog.sections) { section in
                Section {
                    ForEach(section.definitions) { definition in
                        KeyboardShortcutRow(definition: definition)
                    }
                } header: {
                    Text(NSLocalizedString(section.titleKey, comment: ""))
                } footer: {
                    if section == KeyboardShortcutCatalog.sections.last {
                        Text(NSLocalizedString("Keyboard Shortcuts Footer", comment: ""))
                    }
                }
            }
        }
        .formStyle(.grouped)
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
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(definition.displayName)
                if let note = definition.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if isCustomized {
                Button {
                    reset()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help(NSLocalizedString("Reset Shortcut", comment: ""))
                .accessibilityLabel(NSLocalizedString("Reset Shortcut", comment: ""))
            }
            ShortcutRecorderView(shortcut: shortcut) { newValue in
                shortcut = newValue
                KeyboardShortcutStore.shared.setShortcut(newValue, for: definition)
                isCustomized = KeyboardShortcutStore.shared.isCustomized(definition)
            }
        }
    }

    private func reset() {
        let value = definition.defaultShortcut
        shortcut = value
        isCustomized = false
        KeyboardShortcutStore.shared.reset(definition)
    }
}
