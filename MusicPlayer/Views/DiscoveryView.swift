import SwiftUI

struct DiscoveryView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(AppSettings.self) private var settings
    @Environment(BrowserStore.self) private var browserStore
    @Environment(WebMediaDownloader.self) private var downloader
    @Environment(ListeningWrappedService.self) private var wrapped
    @Environment(TrendingArtistsService.self) private var trendingService

    @Binding var showPlayerSheet: Bool
    @Binding var selectedTab: AppTab

    @State private var searchInput = ""
    @FocusState private var isSearchFocused: Bool
    @State private var showSaveLinkAlert = false
    @State private var saveLinkText = ""
    @State private var showWebsiteEditor = false
    @State private var editingSite: SpeedDialSite?
    @State private var siteTitle = ""
    @State private var siteURL = ""
    @State private var showMangaReaderHub = false
    @State private var selectedOnlineManga: OnlineMangaSeries?
    @State private var showWrappedSheet = false
    @State private var mangaService = MangaDexService.shared

    enum TrendingFilterOption: String, CaseIterable, Identifiable {
        case all = "All"
        case youtube = "YouTube"
        case tiktok = "TikTok"
        var id: String { rawValue }
    }
    @State private var trendingFilter: TrendingFilterOption = .all

    private var filteredTrendingSongs: [TrendingSongItem] {
        switch trendingFilter {
        case .all:
            return trendingService.trendingSongs
        case .youtube:
            return trendingService.trendingSongs.filter { $0.platform == .youtube || $0.platform == .combined }
        case .tiktok:
            return trendingService.trendingSongs.filter { $0.platform == .tiktok || $0.platform == .combined }
        }
    }

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

                    if !offlineSongs.isEmpty {
                        shelfSection(
                            title: "Offline Songs",
                            items: offlineSongs,
                            actionTitle: "More"
                        ) {
                            dismissKeyboard()
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
                            dismissKeyboard()
                            selectedTab = .playlists
                        }
                    }

                    mangaShelfSection

                    trendingSongsSection

                    wrappedBannerCard

                    trendingArtistsShelfSection

                    if !browserStore.bookmarks.isEmpty {
                        bookmarksSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Discovery")
            .refreshable {
                await refreshDiscoveryFeeds(force: true)
            }
            .task {
                await refreshDiscoveryFeeds(force: false)
            }
            .onChange(of: showPlayerSheet) { _, _ in
                dismissKeyboard()
            }
            .onChange(of: selectedTab) { _, _ in
                dismissKeyboard()
            }
            .onDisappear {
                dismissKeyboard()
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        dismissKeyboard()
                        showWrappedSheet = true
                    } label: {
                        Label("Wrapped", systemImage: "sparkles")
                    }

                    Button {
                        dismissKeyboard()
                        showMangaReaderHub = true
                    } label: {
                        Label("Manga Reader", systemImage: "book.pages")
                    }

                    Button {
                        dismissKeyboard()
                        selectedTab = .browser
                    } label: {
                        Label("Browser", systemImage: "globe")
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        dismissKeyboard()
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .miniPlayerInset(showPlayerSheet: $showPlayerSheet)
            .sheet(isPresented: $showMangaReaderHub) {
                MangaLibrarySheetView()
            }
            .sheet(item: $selectedOnlineManga) { manga in
                OnlineMangaDetailView(manga: manga)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Menu {
                    Picker("Search Engine", selection: Bindable(settings).searchEngine) {
                        ForEach(SearchEngineOption.allCases) { engine in
                            Label(engine.rawValue, systemImage: engine.systemIcon).tag(engine)
                        }
                    }
                } label: {
                    Text(settings.searchEngine.shortBadge)
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                        .background(
                            (settings.searchEngine == .youtube ? Color.red : Color.accentColor).opacity(0.18),
                            in: Circle()
                        )
                        .foregroundStyle(settings.searchEngine == .youtube ? Color.red : Color.accentColor)
                }

                TextField("Search \(settings.searchEngine.rawValue) or enter web address", text: $searchInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($isSearchFocused)
                    .onSubmit(submitSearch)

                if isSearchFocused || !searchInput.isEmpty {
                    Button {
                        if !searchInput.isEmpty {
                            searchInput = ""
                        } else {
                            dismissKeyboard()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: submitSearch) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(searchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    let featuredEngines: [SearchEngineOption] = [.youtube, .google, .brave]
                    ForEach(featuredEngines) { engine in
                        let selected = settings.searchEngine == engine
                        Button {
                            AppHaptics.selection()
                            settings.searchEngine = engine
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: engine.systemIcon)
                                    .font(.caption2.weight(.bold))
                                Text(engine.rawValue)
                                    .font(.caption.weight(.semibold))
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(
                                selected
                                    ? (engine == .youtube ? Color.red.opacity(0.20) : Color.accentColor.opacity(0.20))
                                    : Color(.secondarySystemBackground),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    selected
                                        ? (engine == .youtube ? Color.red.opacity(0.55) : Color.accentColor.opacity(0.55))
                                        : Color.clear,
                                    lineWidth: 1
                                )
                            )
                            .foregroundStyle(
                                selected
                                    ? (engine == .youtube ? Color.red : Color.accentColor)
                                    : Color.primary
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Menu {
                        ForEach(SearchEngineOption.allCases) { engine in
                            Button {
                                settings.searchEngine = engine
                            } label: {
                                Label(engine.rawValue, systemImage: settings.searchEngine == engine ? "checkmark" : engine.systemIcon)
                            }
                        }
                    } label: {
                        let extraSelected = !featuredEngines.contains(settings.searchEngine)
                        HStack(spacing: 4) {
                            Text(extraSelected ? settings.searchEngine.rawValue : "More")
                                .font(.caption.weight(.semibold))
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.bold))
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            extraSelected ? Color.accentColor.opacity(0.20) : Color(.secondarySystemBackground),
                            in: Capsule()
                        )
                        .foregroundStyle(extraSelected ? Color.accentColor : .secondary)
                    }
                }
            }
        }
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

    private var trendingArtistsShelfSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trending New Artists")
                        .font(.headline)
                    Text("TikTok • IG Reels • Daily 12 AM Auto-Refresh")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                NavigationLink {
                    TrendingArtistsHubView(showPlayerSheet: $showPlayerSheet)
                } label: {
                    Text("See All")
                        .font(.caption.weight(.semibold))
                }
            }

            if trendingService.artists.isEmpty {
                Button {
                    Task { await trendingService.refreshTrendingArtists(force: true) }
                } label: {
                    HStack(spacing: 10) {
                        if trendingService.isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "flame.fill")
                                .foregroundStyle(.pink)
                        }
                        Text(trendingService.isRefreshing ? "Discovering viral artists..." : "Load Trending Artists from TikTok & Reels")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(12)
                    .background(
                        settings.hasCustomBackground ? settings.themedRowBackgroundColor : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(trendingService.isRefreshing)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(trendingService.artists.prefix(15))) { rec in
                            NavigationLink {
                                ArtistProfileView(
                                    artistName: rec.canonicalName,
                                    seedITunesID: rec.iTunesArtistID,
                                    seedDeezerID: rec.deezerArtistID,
                                    seedImageURL: rec.imageURL,
                                    showPlayerSheet: $showPlayerSheet
                                )
                            } label: {
                                VStack(spacing: 6) {
                                    ZStack(alignment: .topTrailing) {
                                        AsyncImage(url: rec.imageURL) { img in
                                            img.resizable().scaledToFill()
                                        } placeholder: {
                                            Circle()
                                                .fill(Color.pink.opacity(0.16))
                                                .overlay {
                                                    Image(systemName: "music.mic")
                                                        .foregroundStyle(.pink)
                                                }
                                        }
                                        .frame(width: 72, height: 72)
                                        .clipShape(Circle())

                                        if rec.isNewSinceStaticCatalog {
                                            Text("NEW")
                                                .font(.system(size: 8, weight: .black))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(Color.pink, in: Capsule())
                                                .foregroundStyle(.white)
                                        }
                                    }

                                    Text(rec.canonicalName)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    if let src = rec.trendSources.first {
                                        Text(src.rawValue)
                                            .font(.caption2)
                                            .foregroundStyle(src.badgeColor)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(width: 78)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var mangaShelfSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Manga")
                    .font(.headline)
                Spacer()
                Button("More") {
                    showMangaReaderHub = true
                }
                .font(.subheadline.weight(.medium))
            }

            if mangaService.popularManga.isEmpty {
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
                                    ? "\(mangaChapterCount) \(mangaChapterCount == 1 ? "item" : "items") ready • Browse Free Manga Server & Offline Reader"
                                    : "Read popular manga free in-app or import .CBZ/.ZIP offline"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }

                        Spacer()
                        if mangaService.isLoadingCatalog {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(12)
                    .background(
                        settings.hasCustomBackground ? settings.themedRowBackgroundColor : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(mangaService.popularManga.prefix(18)) { manga in
                            Button {
                                selectedOnlineManga = manga
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    ZStack(alignment: .bottomLeading) {
                                        AsyncImage(url: manga.thumbnailURL) { img in
                                            img.resizable().scaledToFill()
                                        } placeholder: {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(Color.orange.opacity(0.16))
                                                .overlay {
                                                    Image(systemName: "book.pages.fill")
                                                        .foregroundStyle(.orange)
                                                }
                                        }
                                        .frame(width: 112, height: 158)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                        HStack(spacing: 4) {
                                            Image(systemName: "book.pages.fill")
                                                .font(.system(size: 9, weight: .bold))
                                            Text("Read")
                                                .font(.system(size: 10, weight: .bold))
                                        }
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(.black.opacity(0.68), in: Capsule())
                                        .padding(6)
                                    }

                                    Text(manga.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                        .frame(width: 112, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var trendingSongsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Trending")
                    .font(.headline)

                HStack(spacing: 6) {
                    ForEach(TrendingFilterOption.allCases) { option in
                        let isSelected = trendingFilter == option
                        Button {
                            AppHaptics.selection()
                            trendingFilter = option
                        } label: {
                            Text(option.rawValue)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    isSelected ? Color.accentColor : Color(.secondarySystemBackground),
                                    in: Capsule()
                                )
                                .foregroundStyle(isSelected ? .white : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                if trendingService.isLoadingSongs {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await trendingService.refreshTrendingSongsIfNeeded(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline.weight(.medium))
                    }
                }
            }

            if filteredTrendingSongs.isEmpty {
                VStack(spacing: 10) {
                    if trendingService.isLoadingSongs {
                        ProgressView()
                        Text("Loading trending songs from TikTok & YouTube...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Tap to load trending songs from TikTok & YouTube")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Load Trending Songs") {
                            Task { await trendingService.refreshTrendingSongsIfNeeded(force: true) }
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(filteredTrendingSongs) { song in
                        trendingSongRow(song)
                    }
                }
            }
        }
    }

    private func trendingSongRow(_ song: TrendingSongItem) -> some View {
        let isResolving = trendingService.resolvingSongID == song.id
        return Button {
            dismissKeyboard()
            Task {
                let played = await trendingService.playTrendingSong(song, isVideo: song.videoID != nil)
                if played && song.videoID != nil {
                    dismissKeyboard()
                    showPlayerSheet = true
                }
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    AsyncImage(url: song.artworkURL) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(song.platform.badgeColor.opacity(0.16))
                            .overlay {
                                Image(systemName: song.videoID != nil ? "play.rectangle.fill" : "music.note")
                                    .foregroundStyle(song.platform.badgeColor)
                            }
                    }
                    .frame(width: 124, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    if isResolving {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.black.opacity(0.5))
                            .frame(width: 124, height: 70)
                        ProgressView()
                            .tint(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(song.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Text(song.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(song.platform.rawValue)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(song.platform.badgeColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(song.platform.badgeColor)
                    }
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task {
                    let played = await trendingService.playTrendingSong(song, isVideo: song.videoID != nil)
                    if played && song.videoID != nil {
                        showPlayerSheet = true
                    }
                }
            } label: {
                Label("Play Now", systemImage: "play.fill")
            }

            Button {
                Task {
                    _ = await trendingService.playTrendingSong(song, isVideo: false)
                }
            } label: {
                Label("Play Audio Only", systemImage: "headphones")
            }

            Button {
                Task {
                    _ = await trendingService.cacheTrendingSongOffline(song, downloader: downloader)
                }
            } label: {
                Label("Cache Offline", systemImage: "arrow.down.circle")
            }

            if song.videoID != nil {
                Button {
                    let q = "\(song.artist) \(song.title)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    openURLInBrowser("https://m.youtube.com/results?search_query=\(q)", title: song.title)
                } label: {
                    Label("Search on YouTube", systemImage: "magnifyingglass")
                }
            }
        }
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
                        dismissKeyboard()
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

    private func dismissKeyboard() {
        isSearchFocused = false
        UIApplication.shared.dismissKeyboard()
    }

    private func submitSearch() {
        dismissKeyboard()
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
        dismissKeyboard()
        browserStore.openInActiveTab(urlString: urlString, title: title)
        selectedTab = .browser
    }

    private func refreshDiscoveryFeeds(force: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await MangaDexService.shared.loadCatalogIfNeeded(force: force)
            }
            group.addTask {
                await TrendingArtistsService.shared.refreshTrendingSongsIfNeeded(force: force)
            }
        }
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
