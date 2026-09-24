import SwiftUI

struct HistorySearchView: View {
    @ObservedObject var model: HistorySearchViewModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: model.mode == .url ? "globe" : "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                TextField(placeholder, text: $model.query)
                    .textFieldStyle(.plain).font(.title3).focused($focused)
                    .accessibilityLabel(NSLocalizedString("Search History", comment: ""))
                if model.isSearching { ProgressView().controlSize(.small) }
            }
            .padding(18)

            if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                if model.showsOverallEmptyState {
                    Text(NSLocalizedString("No Search Results", comment: ""))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 28)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                if !model.results.isEmpty {
                                    sectionLabel("Search History Section")
                                }
                                ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                                    HistorySearchResultRow(result: result, isSelected: model.selectedIndex == index)
                                        .id("history:\(result.id)")
                                        .onTapGesture { model.open(result) }
                                        .contextMenu {
                                            Button(role: .destructive) { model.delete(result) } label: {
                                                Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
                                            }
                                        }
                                }
                                if model.mode == .history {
                                    sectionLabel("Local Files Section")
                                    ForEach(Array(model.files.enumerated()), id: \.element.id) { index, file in
                                        SpotlightFileResultRow(file: file, isSelected: model.selectedIndex == model.results.count + index)
                                            .id("file:\(file.id)")
                                            .onTapGesture { model.openFile?(file.url) }
                                    }
                                    if model.isFileSearching {
                                        Text(NSLocalizedString("Searching Local Files", comment: ""))
                                            .foregroundStyle(.secondary).padding(10)
                                    } else if let status = model.fileStatus {
                                        HStack {
                                            Text(NSLocalizedString(status.localizationKey, comment: "")).foregroundStyle(.secondary)
                                            if status.isRetryable {
                                                Button(NSLocalizedString("Retry File Search", comment: "")) { model.retry() }
                                            }
                                        }.padding(10)
                                    } else if model.files.isEmpty {
                                        Text(NSLocalizedString("No Local File Results", comment: ""))
                                            .foregroundStyle(.secondary).padding(10)
                                    }
                                }
                                if let url = model.openURL {
                                    OpenURLSearchResultRow(url: url, isSelected: model.selectedIndex == model.results.count + model.files.count)
                                        .id("url:\(url.absoluteString)")
                                        .onTapGesture { model.openURLResult() }
                                }
                            }
                        }.frame(maxHeight: 560).padding(8)
                        .onChange(of: model.selectedID) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                        .onChange(of: model.itemIDs) { _, _ in
                            if let id = model.selectedID { proxy.scrollTo(id) }
                        }
                    }
                }
            }
            if model.mode == .history {
                HStack {
                    Button(NSLocalizedString("Choose Search Folders", comment: "")) { model.chooseSearchFolders?() }
                    Spacer()
                    if model.hasSearchFolders {
                        Button(NSLocalizedString("Clear Search Folders", comment: "")) { model.clearSearchFolders() }
                    }
                }.font(.caption).padding(.horizontal, 18).padding(.bottom, 12)
            }
            if let error = model.openError {
                Text(error).foregroundStyle(.secondary).padding(12)
            }
        }
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear {
            focused = true
            triggerSelectAllIfNeeded()
        }
        .onChange(of: model.focusRequest) { _, _ in
            focused = true
            triggerSelectAllIfNeeded()
        }
    }

    private func sectionLabel(_ key: String) -> some View {
        Text(NSLocalizedString(key, comment: ""))
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 8)
    }

    private func triggerSelectAllIfNeeded() {
        if model.shouldSelectAll {
            DispatchQueue.main.async {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private var placeholder: String {
        switch model.mode {
        case .history: NSLocalizedString("Search History Placeholder", comment: "")
        case .url: NSLocalizedString("Enter URL Placeholder", comment: "")
        }
    }
}
