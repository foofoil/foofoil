import SwiftUI

struct HistorySearchView: View {
    @ObservedObject var model: HistorySearchViewModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: model.mode == .url ? "globe" : "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                if let scope = model.activeScope {
                    HStack(spacing: 5) {
                        Image(systemName: scope.symbolName)
                            .font(.system(size: 11))
                        Text(scope.displayName)
                            .font(.system(size: 13, weight: .medium))
                        Button {
                            model.clearActiveScope()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundStyle(Color.accentColor)
                }
                TextField(placeholder, text: $model.query)
                    .textFieldStyle(.plain).font(.title3).focused($focused)
                    .accessibilityLabel(NSLocalizedString("Search History", comment: ""))
                if model.isSearching { ProgressView().controlSize(.small) }
            }
            .padding(18)

            if model.isPickingScope {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.filteredScopes.enumerated()), id: \.element.id) { index, scope in
                        Button {
                            model.selectScope(scope)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: scope.symbolName)
                                    .font(.body)
                                    .frame(width: 20)
                                    .foregroundStyle(index == model.highlightedScopeIndex ? Color.accentColor : .secondary)
                                Text(scope.displayName)
                                    .font(.body)
                                    .foregroundStyle(index == model.highlightedScopeIndex ? Color.accentColor : .primary)
                                Spacer()
                                Text(scope.englishName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(index == model.highlightedScopeIndex ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                    }
                    if model.filteredScopes.isEmpty {
                        Text(NSLocalizedString("No Matching Scopes", comment: ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(8)
            } else if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                if let link = model.musicLink {
                    VStack(alignment: .leading, spacing: 8) {
                        AppleMusicLinkResultRow(link: link, item: model.linkedMusicItem,
                                               isSelected: model.selectedID != nil)
                            .contentShape(Rectangle()).onTapGesture { model.openLinkedMusic() }
                        if let error = model.musicLinkError {
                            Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
                            Button(NSLocalizedString("Retry File Search", comment: "")) { model.retry() }
                                .font(.caption).padding(.horizontal, 10)
                        }
                    }.padding(8)
                } else if model.showsOverallEmptyState {
                    Text(NSLocalizedString("No Search Results", comment: ""))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 28)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                if model.showsOpenCamera {
                                    Button { model.openCamera?() } label: {
                                        Label(NSLocalizedString("Open Camera", comment: ""), systemImage: "camera")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                        .buttonStyle(.plain)
                                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(model.selectedID == "camera" ? Color.accentColor.opacity(0.15) : Color.clear)
                                        .contentShape(Rectangle()).id("camera")
                                }
                                if !model.visibleResults.isEmpty {
                                    sectionLabel("Search History Section")
                                }
                                ForEach(Array(model.visibleResults.enumerated()), id: \.element.id) { index, result in
                                    HistorySearchResultRow(result: result, isSelected: model.selectedID == "history:\(result.id)")
                                        .id("history:\(result.id)")
                                        .onTapGesture { model.open(result) }
                                        .contextMenu {
                                            Button { model.togglePinned(result) } label: {
                                                Label(NSLocalizedString(result.historyIsPinned ? "Unfavorite History" : "Favorite History", comment: ""), systemImage: result.historyIsPinned ? "bookmark.slash.fill" : "bookmark.fill")
                                            }

                                            Button(role: .destructive) { model.delete(result) } label: {
                                                Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
                                            }
                                        }
                                }
                                if model.canExpandHistoryResults {
                                    Button(NSLocalizedString("Search More History", comment: "")) { model.expandHistoryResults() }
                                        .font(.caption).padding(10)
                                }
                                if model.mode == .history && model.resultFilter.includesFiles {
                                    sectionLabel(model.resultFilter.fileSectionLocalizationKey)
                                    ForEach(Array(model.visibleFiles.enumerated()), id: \.element.id) { index, file in
                                        SpotlightFileResultRow(file: file, isSelected: model.selectedID == "file:\(file.id)")
                                            .id("file:\(file.id)")
                                            .onTapGesture { model.openFile?(file.url) }
                                    }
                                    if model.canExpandFileResults {
                                        Button(NSLocalizedString(model.resultFilter.moreFilesLocalizationKey, comment: "")) { model.expandFileResults() }
                                            .font(.caption).padding(10)
                                    }
                                    if model.isFileSearching {
                                        SearchLoadingStatusView(text: NSLocalizedString(model.resultFilter.searchingFilesLocalizationKey, comment: ""))
                                            .padding(10)
                                    } else if let status = model.fileStatus {
                                        HStack {
                                            Text(NSLocalizedString(status.localizationKey, comment: "")).foregroundStyle(.secondary)
                                            if status.isRetryable {
                                                Button(NSLocalizedString("Retry File Search", comment: "")) { model.retry() }
                                            }
                                        }.padding(10)
                                    } else if model.files.isEmpty {
                                        Text(NSLocalizedString(model.resultFilter.noFilesLocalizationKey, comment: ""))
                                            .foregroundStyle(.secondary).padding(10)
                                    }
                                }
                                if model.mode == .history, (model.resultFilter == .all || model.resultFilter.musicCategory != nil), model.isMusicSearchEnabled, model.isMusicAuthorized {
                                    ForEach(AppleMusicSearchCategory.allCases.filter { model.resultFilter.includes($0) }) { category in
                                        if !model.musicResults(in: category).isEmpty {
                                            sectionLabel(category.sectionLocalizationKey)
                                            ForEach(model.visibleMusicResults(in: category)) { item in
                                                AppleMusicSearchResultRow(item: item, isSelected: model.selectedID == "music:\(item.id)")
                                                    .id("music:\(item.id)")
                                                    .onTapGesture { model.openMusic?(item) }
                                            }
                                            if model.canExpandMusicResults(in: category) {
                                                Button(NSLocalizedString(category.moreLocalizationKey, comment: "")) {
                                                    model.expandMusicResults(in: category)
                                                }.font(.caption).padding(10)
                                            }
                                        }
                                    }
                                    if model.isMusicSearching {
                                        SearchLoadingStatusView(text: NSLocalizedString("Searching Music Library", comment: ""))
                                            .padding(10)
                                    }
                                    if let error = model.musicError {
                                        Text(error).foregroundStyle(.secondary).padding(10)
                                    }
                                }
                                if model.showsResultLimitNotice {
                                    Text(String(format: NSLocalizedString("Search Result Limit Notice Format", comment: ""), model.resultCount))
                                        .font(.caption).foregroundStyle(.secondary).padding(10)
                                }
                                if let url = model.openURL {
                                    OpenURLSearchResultRow(url: url, isSelected: model.selectedID == "url:\(url.absoluteString)")
                                        .id("url:\(url.absoluteString)")
                                        .onTapGesture { model.openURLResult() }
                                }
                            }
                        }.frame(maxHeight: 560).padding(8)
                        .onChange(of: model.selectedID) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                        .onChange(of: model.itemIDs) { _, _ in
                            // 点击「更多」时保留阅读位置，避免新增结果把列表拉回高亮的首项。
                            guard !model.hasExpandedResults else { return }
                            if let id = model.selectedID { proxy.scrollTo(id) }
                        }
                    }
                }
            }
            // ⌘P 面板只提供开启文件搜索的入口；关闭文件搜索在设置中完成。
            if model.musicLink == nil, model.mode == .history, model.resultFilter.includesFiles, !model.isFileSearchAuthorized {
                HStack {
                    Button(NSLocalizedString("Enable File Search", comment: "")) { model.enableFileSearch?() }
                    Spacer()
                }.font(.caption).padding(.horizontal, 18).padding(.bottom, 12)
            }
            if (model.musicLink != nil || (model.mode == .history && (model.resultFilter == .all || model.resultFilter.musicCategory != nil) && model.isMusicSearchEnabled)), !model.isMusicAuthorized {
                HStack {
                    Button(NSLocalizedString(model.musicLink == nil ? "Music Enable Search" : "Music Authorize", comment: "")) { model.enableMusicSearch?() }
                    Spacer()
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
        .foilToast(model.toast)
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
        if let scope = model.activeScope {
            return String(format: NSLocalizedString("Search In Scope Placeholder", comment: ""), scope.displayName)
        }
        switch model.mode {
        case .history:
            return NSLocalizedString(model.isMusicSearchEnabled && model.isMusicAuthorized ? "Music Quick Open Placeholder" : "Search History Placeholder", comment: "")
        case .url:
            return NSLocalizedString("Enter URL Placeholder", comment: "")
        }
    }
}
