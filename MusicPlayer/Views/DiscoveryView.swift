import SwiftUI

struct DiscoveryView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(AppSettings.self) private var settings
    @Environment(BrowserStore.self) private var browserStore
    @Environment(WebMediaDownloader.self) private var downloader
    @Environment(ListeningWrappedService.self) private var wrapped

    @Binding var showPlayerSheet: Bool
    @Binding var selectedTab: AppTab

    @State private var searchInput = ""
    @State private var showSaveLinkAlert = false
    @State private var saveLinkText = ""
    @State private var showWebsiteEditor = false
    @State private var editingSite: SpeedDialSite?
    @State private var siteTitle = ""
    @State private var siteURL = ""
    @State private var showMangaReaderHub = false
    @State private var showWrappedSheet = false

    private let columns = [
        GridItem(.adaptive(minimum: 74, maximum: 92), spacing: 12)
    ]

    private var offlineSongs: [MediaItem] {
        Array(mediaManager.items.filter { !$0.isVideo }.prefix(8))
    }

    private var recentItems: [MediaItem] {
        Array(mediaManager.recentItems.prefix(8))
    }

    private var mangaChapterCount: Int {
        mediaManager.mangaImageChapters().count + mediaManager.otherFiles.filter { $0.isArchive || $0.isReadableText }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    searchBarSection

                    speedDialSection

                    wrappedBannerCard

                    mangaReaderCard

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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showWrappedSheet = true
                    } label: {
                        Label("Wrapped", systemImage: "sparkles")
                    }

                    Button {
                        showMangaReaderHub = true
                    } label: {
                        Label("Manga Reader", systemImage: "book.pages")
                    }

                    Button {
                        selectedTab = .browser
                    } label: {
                        Label("Browser", systemImage: "globe")
                    }
                }
            }
            .miniPlayerInset(showPlayerSheet: $showPlayerSheet)
            .sheet(isPresented: $showMangaReaderHub) {
                MangaLibrarySheetView()
            }
            .sheet(isPresented: $showWrappedSheet) {
                WrappedDashboardSheet()
            }
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

    private var wrappedBannerCard: some View {
        let _ = wrapped.lastUpdatedTick
        let year = Calendar.current.component(.year, from: .now)
        let report = wrapped.report(forYear: year)
        let isDec = ListeningWrappedService.isDecemberRevealActive()
        let daysLeft = ListeningWrappedService.daysUntilDecemberFirst()

        return Button {
            showWrappedSheet = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.45, green: 0.14, blue: 0.85), Color.pink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 48, height: 48)
                    Image(systemName: isDec ? "crown.fill" : "sparkles")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isDec ? .yellow : .white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(isDec ? "\(String(year)) Wrapped Drop Is Ready!" : "\(String(year)) Listening Wrapped")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(
                        report.heroTopArtist.map { hero in
                            isDec
                                ? "#1 Artist of the Year: \(hero.canonicalName) • \(ListeningWrappedService.formatHoursMinutes(hero.totalSeconds))"
                                : "Dec 1 Drop in \(daysLeft)d • Leading: \(hero.canonicalName)"
                        } ?? "Tracks your top artists for the Dec 1st Year-End Reveal"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(
                settings.hasCustomBackground ? settings.themedRowBackgroundColor : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private var mangaReaderCard: some View {
        Button {
            showMangaReaderHub = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.orange.opacity(0.85), Color.pink.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 48, height: 48)
                    Image(systemName: "book.pages.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Manga, Comic & Story Reader")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(
                        mangaChapterCount > 0
                            ? "\(mangaChapterCount) \(mangaChapterCount == 1 ? "item" : "items") ready • Scroll, Page & Manga RTL"
                            : "Read image folders, .CBZ/.ZIP comics & .TXT stories offline"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(
                settings.hasCustomBackground ? settings.themedRowBackgroundColor : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(.plain)
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
