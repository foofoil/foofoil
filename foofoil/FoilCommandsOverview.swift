import Foundation

@MainActor
enum FoilCommandsOverview {
    nonisolated static let sourceFingerprint = "foofoil:foil-commands-overview"

    static func markdown() -> String {
        guard let url = Bundle.main.url(forResource: "FoilCommands", withExtension: "md") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

extension AppState {
    func openFoilCommandsOverview() {
        openText(FoilCommandsOverview.markdown(), isMarkdown: true)
        sourceFingerprint = FoilCommandsOverview.sourceFingerprint
        originalImageName = NSLocalizedString("Foil Commands Overview", comment: "") + ".md"
        saveState()
    }
}
