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
    private var fonts: [String] { NSFontManager.shared.availableFontFamilies.sorted() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Subtitle Global Settings Notice").font(.caption).foregroundStyle(.secondary)
                Picker("Subtitle Theme", selection: Binding(get: { store.style.theme }, set: { name in
                    if let theme = SubtitleStyle.themes.first(where: { $0.0 == name }) { store.applyTheme(theme.1) }
                })) {
                    ForEach(SubtitleStyle.themes, id: \.0) { theme in Text(LocalizedStringKey(theme.0)).tag(theme.0) }
                    Text("Custom").tag("Custom")
                }
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
                Toggle("Show Subtitles", isOn: Binding(get: { !controller.association.isHidden }, set: { visible in
                    if visible {
                        if let path = controller.association.selectedPath, let file = controller.association.files.first(where: { $0.path == path }) { controller.selectFile(file) }
                        else { controller.useEmbedded(controller.association.embeddedID) }
                    } else { controller.hide() }
                }))
                Button("Load Subtitle File") { controller.pickFile() }
                if let failure = controller.failure { Text(failure).font(.caption).foregroundStyle(.red) }
            }.padding(20)
        }
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
