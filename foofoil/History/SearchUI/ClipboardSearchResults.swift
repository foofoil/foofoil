import SwiftUI

struct ClipboardSearchResults: View {
    @ObservedObject var search: ClipboardHistorySearch
    let selectedID: String?
    let open: (ClipboardSearchEntry) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(search.entries) { entry in
                            HStack(spacing: 4) {
                                Button { open(entry) } label: {
                                    HStack(alignment: .center, spacing: 10) {
                                        ClipboardEntryArtwork(entry: entry).frame(width: 44, height: 44).accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(entry.title).lineLimit(1).truncationMode(.tail)
                                            Text(entry.searchText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if !entry.isCurrentClipboard {
                                    Button { search.copy(entry) } label: {
                                        Image(systemName: "doc.on.doc").padding(8)
                                    }.buttonStyle(.plain).disabled(!entry.canCopy)
                                        .help(NSLocalizedString("Clipboard History Copy", comment: ""))
                                        .accessibilityLabel(NSLocalizedString("Clipboard History Copy", comment: ""))
                                        .accessibilityIdentifier("clipboard.copy.\(entry.id)")
                                }
                            }.background(selectedID == "clipboard:\(entry.id)" ? Color.accentColor.opacity(0.15) : Color.clear)
                                .id("clipboard:\(entry.id)")
                        }
                        if search.isLoading { ProgressView().controlSize(.small).padding(10) }
                        else if search.entries.isEmpty {
                            Text(NSLocalizedString("No Search Results", comment: "")).foregroundStyle(.secondary).padding(10)
                        }
                    }
                }.frame(maxHeight: 460)
                    .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
            }
            if let error = search.copyError { Text(error).font(.caption).foregroundStyle(.secondary) }
            if search.access == .needsAuthorization {
                Text(NSLocalizedString("Clipboard History Authorization Instructions", comment: ""))
                    .font(.caption).foregroundStyle(.secondary)
                Button(NSLocalizedString("Clipboard History Authorize", comment: "")) { search.openAuthorizationSettings() }
                    .accessibilityIdentifier("clipboard.authorize")
            } else if search.access == .unavailable {
                Text(NSLocalizedString("Clipboard History Unavailable", comment: "")).font(.caption).foregroundStyle(.secondary)
                Button(NSLocalizedString("Retry File Search", comment: "")) { search.refresh() }
            }
        }.padding(12)
    }
}
