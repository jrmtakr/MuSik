import SwiftUI

struct DiscoveryView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(AppSettings.self) private var settings
    @Environment(BrowserStore.self) private var browserStore
    @Environment(WebMediaDownloader.self) private var downloader

    @Binding var showPlayerSheet: Bool
    @Binding var selectedTab: AppTab

    @State private var searchInput = ""
    @State private var showSaveLinkAlert = false
    @State private var saveLinkText = ""
    @State private var showWebsiteEditor = false
    @State private var editingSite: SpeedDialSite?
    @State private var siteTitle = ""
    @State private var siteURL = ""

    private let columns = [
        GridItem(.adaptive(minimum: 74, maximum: 92), spacing: 12)
    ]

    private var offlineSongs: [MediaItem] {
        Array(mediaManager.items.filter { !$0.isVideo }.prefix(8))
    }

    private var recentItems: [MediaItem] {
        Array(mediaManager.recentItems.prefix(8))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    searchBarSection

                    speedDialSection

                    if !offlineSongs.isEmpty {
                        shelfSection(
                            title: "Offline Songs",
                            items: offlineSongs,
                            actionTitle: "Play All"
                        ) {
                            if let first = offlineSongs.first {
                                mediaManager.play(first)
                            }
                        }
                    }

                    if !recentItems.isEmpty {
                        shelfSection(
                            title: "Last Played",
                            items: recentItems,
                            actionTitle: "More"
                        ) {
                            selectedTab = .playlists
                        }
                    }

                    if !browserStore.bookmarks.isEmpty {
                        bookmarksSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("Discovery")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        selectedTab = .browser
                    } label: {
                        Label("Browser", systemImage: "globe")
                    }
                }
            }
            .miniPlayerInset(showPlayerSheet: $showPlayerSheet)
            .alert("Save Media Link", isPresented: $showSaveLinkAlert) {
                TextField("https://... (.mp4, .mp3, .m3u8, or page)", text: $saveLinkText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) { saveLinkText = "" }
                Button("Download") {
                    let raw = saveLinkText
                    saveLinkText = ""
                    Task {
                        await downloader.resolveAndDownload(
                            inputURLString: raw,
                            maxDurationMinutes: settings.maxCacheDurationMinutes
                        )
                    }
                }
            } message: {
                Text("Paste a direct media URL or webpage link to download for offline playback.")
            }
            .alert(editingSite == nil ? "New website" : "Modify website", isPresented: $showWebsiteEditor) {
                TextField("Website title", text: $siteTitle)
                TextField("Website address", text: $siteURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) {
                    editingSite = nil
                }
                Button("Save") {
                    let cleanTitle = siteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    let cleanURL = siteURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleanURL.isEmpty else {
                        mediaManager.errorMessage = "Please enter a valid website address"
                        return
                    }
                    browserStore.addOrUpdateSpeedDial(
                        id: editingSite?.id,
                        title: cleanTitle,
                        urlString: cleanURL
                    )
                    editingSite = nil
                }
            }
        }
    }

    private var searchBarSection: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Search Engine", selection: Bindable(settings).searchEngine) {
                    ForEach(SearchEngineOption.allCases) { engine in
                        Text(engine.rawValue).tag(engine)
                    }
                }
            } label: {
                Text(settings.searchEngine.shortBadge)
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.18), in: Circle())
                    .foregroundStyle(Color.accentColor)
            }

            TextField("Search or enter web address", text: $searchInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(submitSearch)

            Button(action: submitSearch) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(searchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : Color.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var speedDialSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Websites")
                    .font(.headline)
                Spacer()
                Button {
                    editingSite = nil
                    siteTitle = ""
                    siteURL = ""
                    showWebsiteEditor = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
            }

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(browserStore.speedDialSites) { site in
                    Button {
                        openURLInBrowser(site.urlString, title: site.title)
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(Color(hex: site.hexColor).opacity(0.18))
                                    .frame(width: 54, height: 54)
                                Text(site.shortLabel)
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(Color(hex: site.hexColor))
                            }
                            Text(site.title)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            openURLInBrowser(site.urlString, title: site.title)
                        } label: {
                            Label("Open", systemImage: "safari")
                        }

                        Button {
                            editingSite = site
                            siteTitle = site.title
                            siteURL = site.urlString
                            showWebsiteEditor = true
                        } label: {
                            Label("Modify website", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            browserStore.deleteSpeedDial(site)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }

                Button {
                    saveLinkText = UIPasteboard.general.string?.hasPrefix("http") == true ? (UIPasteboard.general.string ?? "") : ""
                    showSaveLinkAlert = true
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.16))
                                .frame(width: 54, height: 54)
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                        }
                        Text("Save Link")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func shelfSection(
        title: String,
        items: [MediaItem],
        actionTitle: String,
        onAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button(actionTitle, action: onAction)
                    .font(.subheadline.weight(.medium))
            }

            VStack(spacing: 8) {
                ForEach(items) { item in
                    Button {
                        mediaManager.play(item)
                        if item.isVideo {
                            showPlayerSheet = true
                        }
                    } label: {
                        HStack(spacing: 12) {
                            MediaArtworkView(
                                item: item,
                                image: mediaManager.thumbnails[item.relativePath],
                                cornerRadius: 8,
                                iconSize: 16
                            )
                            .frame(width: 46, height: 46)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(mediaManager.currentItem?.relativePath == item.relativePath ? Color.accentColor : .primary)
                                    .lineLimit(1)
                                Text(shelfSubtitle(for: item))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: mediaManager.currentItem?.relativePath == item.relativePath && mediaManager.isPlaying ? "waveform" : "play.circle")
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var bookmarksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bookmarks")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(browserStore.bookmarks.prefix(10)) { bm in
                        Button {
                            openURLInBrowser(bm.urlString, title: bm.title)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "bookmark.fill")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                Text(bm.title)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func submitSearch() {
        guard let target = resolvedInputURL(searchInput) else { return }
        openURLInBrowser(target.absoluteString, title: searchInput)
        searchInput = ""
    }

    private func resolvedInputURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        if trimmed.contains("."), !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }
        return settings.searchEngine.searchURL(for: trimmed)
    }

    private func openURLInBrowser(_ urlString: String, title: String? = nil) {
        browserStore.openInActiveTab(urlString: urlString, title: title)
        selectedTab = .browser
    }

    private func shelfSubtitle(for item: MediaItem) -> String {
        var parts: [String] = []
        if let artist = item.artist, !artist.isEmpty {
            parts.append(artist)
        } else {
            parts.append(item.fileExtension.uppercased())
        }
        if let duration = item.formattedDuration {
            parts.append(duration)
        }
        parts.append(item.formattedFileSize)
        return parts.joined(separator: " • ")
    }
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
