import AppKit
import SwiftUI

@MainActor final class SubtitleStylePanelController: NSWindowController {
    static let shared = SubtitleStylePanelController()
    private(set) weak var attachedState: AppState?
    private convenience init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 590),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = NSLocalizedString("Subtitle Style", comment: "")
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary]; panel.minSize = NSSize(width: 360, height: 450)
        self.init(window: panel)
    }
    func show(for state: AppState) {
        attachedState = state
        window?.contentView = NSHostingView(rootView: SubtitleStyleView(controller: state.subtitles))
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }
    func dismiss(ownedBy state: AppState) {
        guard attachedState === state else { return }
        attachedState = nil; window?.contentView = nil; close()
    }
}
struct SubtitleStyleView: View {
    @ObservedObject var controller: VideoSubtitleController
    @ObservedObject private var store = SubtitleStyleStore.shared
    @State private var showingSaveTheme = false
    @State private var themeName = ""
    @State private var replacementThemeID = ""
    private var fonts: [String] { NSFontManager.shared.availableFontFamilies.sorted() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Subtitle Global Settings Notice").font(.caption).foregroundStyle(.secondary)
                themeSection
                Picker("Font", selection: binding(\.font)) {
                    Text("System Font").tag("")
                    ForEach(fonts, id: \.self) { Text($0).tag($0) }
                }
                HStack { Text("Subtitle Font Size"); Spacer(); TextField("Subtitle Font Size", value: binding(\.size), format: .number).frame(width: 70) }
                Slider(value: binding(\.size), in: 12...120)
                color("Text Color", \.color)
                color("Background Color", \.background)
                color("Subtitle Shadow Color", \.shadow)
                HStack { Text("Subtitle Bottom Position"); Spacer(); Text(String(format: "%.1f%%", store.style.bottom)).monospacedDigit() }
                Slider(value: binding(\.bottom), in: 0...40)
                HStack {
                    Text("Subtitle Delay")
                    Spacer()
                    TextField("Subtitle Delay", value: binding(\.delay), format: .number).frame(width: 75)
                    Text("Seconds")
                    Button("Reset") { store.style.delay = 0 }
                }
                Text("Subtitle Positive Delay Notice").font(.caption).foregroundStyle(.secondary)
                Text("Subtitle Bitmap Styling Notice").font(.caption).foregroundStyle(.secondary)
                Divider()
                SubtitleVisibilityToggle(controller: controller)
                if let failure = controller.failure { Text(failure).font(.caption).foregroundStyle(.red) }
            }.padding(20)
        }
    }
    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Subtitle Theme").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save as Theme...") {
                    themeName = ""; replacementThemeID = ""; showingSaveTheme = true
                }
                .sheet(isPresented: $showingSaveTheme) { saveThemePopover }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(SubtitleStyle.themes, id: \.0) { theme in
                    themeCard(id: theme.0, name: NSLocalizedString(theme.0, comment: ""), style: theme.1,
                              description: NSLocalizedString(SubtitleStyle.descriptions[theme.0] ?? "", comment: "")) {
                        store.applyTheme(theme.1)
                    }
                }
                ForEach(store.customThemes) { theme in
                    themeCard(id: theme.id, name: theme.name, style: theme.style,
                              description: NSLocalizedString("Custom Theme", comment: "")) {
                        store.selectTheme(theme)
                    }
                    .contextMenu {
                        Button("Replace with Current Style") { store.saveTheme(name: theme.name, replacing: theme.id) }
                        Button("Delete Theme", role: .destructive) { store.deleteTheme(id: theme.id) }
                    }
                }
            }
            Text("Theme Management Help").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func themeCard(id: String, name: String, style: SubtitleStyle, description: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                // 用相同的文字、背景和阴影设置展示预设，方便比较遮挡和清晰度。
                Text("Subtitle Preview Text")
                    .font(style.font.isEmpty ? .system(size: 14, weight: .semibold) : .custom(style.font, size: 14))
                    .foregroundStyle(SubtitleStyleStore.color(style.color))
                    .shadow(color: SubtitleStyleStore.color(style.shadow), radius: 1, x: 0, y: 1)
                    .padding(5)
                    .background(SubtitleStyleStore.color(style.background), in: RoundedRectangle(cornerRadius: 3))
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(LinearGradient(colors: [Color(red: 0.24, green: 0.32, blue: 0.4), Color(red: 0.55, green: 0.48, blue: 0.4)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 4))
                HStack {
                    Text(verbatim: name).font(.caption).lineLimit(1)
                    Spacer(minLength: 0)
                    if store.style.theme == id { Image(systemName: "checkmark").font(.caption2).foregroundStyle(Color.accentColor) }
                }
                Text(verbatim: description).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(store.style.theme == id ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name + ", " + description)
    }
    private var saveThemePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Custom Theme").font(.headline)
            Picker("Save Theme Destination", selection: $replacementThemeID) {
                Text("New Theme").tag("")
                ForEach(store.customThemes) { Text(verbatim: $0.name).tag($0.id) }
            }
            .onChange(of: replacementThemeID) { _, id in
                themeName = store.customThemes.first { $0.id == id }?.name ?? ""
            }
            TextField("Theme Name", text: $themeName).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showingSaveTheme = false }
                Button(replacementThemeID.isEmpty ? NSLocalizedString("Save", comment: "") : NSLocalizedString("Overwrite Theme", comment: "")) {
                    store.saveTheme(name: themeName, replacing: replacementThemeID.isEmpty ? nil : replacementThemeID)
                    showingSaveTheme = false
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(14).frame(width: 270)
    }
    private func binding<T>(_ key: WritableKeyPath<SubtitleStyle, T>) -> Binding<T> {
        Binding(get: { store.style[keyPath: key] }, set: { value in
            var style = store.style; style[keyPath: key] = value; style.theme = "Custom"
            style.size = min(120, max(12, style.size.isFinite ? style.size : 44))
            style.bottom = min(40, max(0, style.bottom.isFinite ? style.bottom : 6))
            style.delay = min(120, max(-120, style.delay.isFinite ? style.delay : 0))
            store.style = style
        })
    }
    private func color(_ title: String, _ key: WritableKeyPath<SubtitleStyle, String>) -> some View {
        ColorPicker(LocalizedStringKey(title), selection: Binding(get: { SubtitleStyleStore.color(store.style[keyPath: key]) }, set: {
            var style = store.style; style[keyPath: key] = SubtitleStyleStore.hex($0); style.theme = "Custom"; store.style = style
        }), supportsOpacity: true)
    }
}
