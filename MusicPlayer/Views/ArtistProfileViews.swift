import SwiftUI

struct ArtistProfileView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(WebMediaDownloader.self) private var downloader
    @Environment(ListeningWrappedService.self) private var wrapped
    @Environment(TrendingArtistsService.self) private var trendingService

    let artistName: String
    var seedITunesID: Int? = nil
    var seedDeezerID: Int? = nil
    var seedImageURL: URL? = nil
    var showPlayerSheet: Binding<Bool>? = nil

    @State private var profile: ArtistProfileBundle?
    @State private var isLoading = true
    @State private var downloadingKeys: Set<String> = []
    @State private var busyStreamKey: String?
    @State private var localPlayerSheet = false

    private var playerSheetBinding: Binding<Bool> {
        showPlayerSheet ?? $localPlayerSheet
    }

    private var offlineArtistTracks: [MediaItem] {
        let targetKey = ArtistDatabase.normalizeLookupKey(profile?.canonicalName ?? artistName)
        guard !targetKey.isEmpty else { return [] }
        return mediaManager.items.filter { item in
            let assessment = wrapped.assessItem(item, metadataByPath: mediaManager.customMetadataByPath)
            return ArtistDatabase.normalizeLookupKey(assessment.artist) == targetKey
        }
    }

    private var currentYearStats: WrappedArtistRanking? {
        let _ = wrapped.lastUpdatedTick
        let year = Calendar.current.component(.year, from: .now)
        let targetKey = ArtistDatabase.normalizeLookupKey(profile?.canonicalName ?? artistName)
        return wrapped.report(forYear: year).allArtists.first { $0.normalizedKey == targetKey }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let profile {
                    ArtistHeroBannerView(
                        profile: profile,
                        offlineCount: offlineArtistTracks.count,
                        onPlayTop: { Task { await playArtistHero(profile: profile, shuffled: false) } },
                        onShuffleTop: { Task { await playArtistHero(profile: profile, shuffled: true) } }
                    )

                    personalStatsSection(profile: profile)
                        .padding(.horizontal, 16)

                    if let latest = profile.latestRelease {
                        LatestReleaseBannerView(release: latest, showPlayerSheet: playerSheetBinding)
                            .padding(.horizontal, 16)
                    }

                    if !profile.topSongs.isEmpty {
                        topSongsSection(songs: profile.topSongs)
                            .padding(.horizontal, 16)
                    }

                    if !profile.albums.isEmpty {
                        ArtistReleasesShelfView(
                            title: "Albums",
                            releases: profile.albums,
                            showPlayerSheet: playerSheetBinding
                        )
                    }

                    if !profile.singlesAndEPs.isEmpty {
                        ArtistReleasesShelfView(
                            title: "Singles & EPs",
                            releases: profile.singlesAndEPs,
                            showPlayerSheet: playerSheetBinding
                        )
                    }

                    if !profile.musicVideos.isEmpty {
                        ArtistMusicVideosShelfView(
                            videos: profile.musicVideos,
                            busyVideoID: busyStreamKey,
                            onPlayVideo: { mv in
                                Task { await playMusicVideo(mv) }
                            }
                        )
                    }

                    if !profile.similarArtists.isEmpty {
                        SimilarArtistsShelfView(
                            artists: profile.similarArtists,
                            showPlayerSheet: playerSheetBinding
                        )
                    }
                } else if isLoading {
                    VStack(spacing: 14) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Loading artist profile & releases...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 90)
                } else {
                    ContentUnavailableView(
                        "Artist Profile Unavailable",
                        systemImage: "music.mic",
                        description: Text("Check your internet connection to load \(artistName)'s catalog.")
                    )
                }
            }
            .padding(.bottom, 28)
        }
        .applyAppTheme()
        .navigationTitle(profile?.canonicalName ?? artistName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: artistName) {
            isLoading = true
            profile = await trendingService.loadArtistProfile(
                artistName: artistName,
                seedITunesID: seedITunesID,
                seedDeezerID: seedDeezerID,
                seedImageURL: seedImageURL
            )
            isLoading = false
        }
        .sheet(isPresented: $localPlayerSheet) {
            if showPlayerSheet == nil {
                NowPlayingView()
            }
        }
    }

    @ViewBuilder
    private func personalStatsSection(profile: ArtistProfileBundle) -> some View {
        if currentYearStats != nil || !offlineArtistTracks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let stats = currentYearStats {
                    HStack(spacing: 10) {
                        Image(systemName: "crown.fill")
                            .foregroundStyle(.yellow)
                        Text("Your 2026 Listening: \(ListeningWrappedService.formatHoursMinutes(stats.totalSeconds)) • \(stats.playCount) streams")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.purple.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if !offlineArtistTracks.isEmpty {
                    Text("\(offlineArtistTracks.count) Offline \(offlineArtistTracks.count == 1 ? "Track" : "Tracks") in Your Library")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func topSongsSection(songs: [ArtistTopSongItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top Songs")
                .font(.title3.weight(.bold))

            LazyVStack(spacing: 8) {
                ForEach(Array(songs.prefix(12).enumerated()), id: \.element.id) { idx, song in
                    let isDownloading = downloadingKeys.contains(song.id)
                    let isPlayingThis = busyStreamKey == song.id
                    let localMatch = offlineMatch(title: song.title)

                    HStack(spacing: 12) {
                        AsyncImage(url: song.artworkURL) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.accentColor.opacity(0.14))
                                .overlay {
                                    Text("\(idx + 1)")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Color.accentColor)
                                }
                        }
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Button {
                            if let localMatch {
                                mediaManager.play(localMatch)
                                if localMatch.isVideo { playerSheetBinding.wrappedValue = true }
                            } else {
                                Task { await streamSongAdFree(song) }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                HStack(spacing: 5) {
                                    if localMatch != nil {
                                        Image(systemName: "arrow.down.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    }
                                    Text(song.albumTitle ?? song.artistName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    if let d = song.durationSeconds, d > 0 {
                                        Text("• \(MediaTimeFormatter.format(d))")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if isPlayingThis {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else if localMatch == nil {
                            if isDownloading {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Button {
                                    Task { await saveSongOffline(song) }
                                } label: {
                                    Image(systemName: "arrow.down.circle")
                                        .font(.title3)
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func offlineMatch(title: String) -> MediaItem? {
        let target = ArtistDatabase.normalizeLookupKey(ArtistDatabase.cleanSongTitleForSearch(rawTitle: title).songOnly)
        return offlineArtistTracks.first { item in
            let cand = ArtistDatabase.normalizeLookupKey(
                ArtistDatabase.cleanSongTitleForSearch(rawTitle: item.displayTitle, rawArtistTag: item.artist).songOnly
            )
            return cand == target || (!target.isEmpty && cand.contains(target))
        }
    }

    private func playArtistHero(profile: ArtistProfileBundle, shuffled: Bool) async {
        if !offlineArtistTracks.isEmpty {
            let pick = shuffled ? offlineArtistTracks.randomElement() : offlineArtistTracks.first
            if let pick {
                mediaManager.isShuffleEnabled = shuffled
                mediaManager.play(pick)
                return
            }
        }
        let targetSong = shuffled ? profile.topSongs.randomElement() : profile.topSongs.first
        if let targetSong {
            await streamSongAdFree(targetSong)
        }
    }

    private func streamSongAdFree(_ song: ArtistTopSongItem) async {
        busyStreamKey = song.id
        _ = await trendingService.playArtistTrackAdFree(
            title: song.title,
            artist: profile?.canonicalName ?? song.artistName,
            isVideo: false
        )
        busyStreamKey = nil
    }

    private func playMusicVideo(_ video: ArtistMusicVideoItem) async {
        let key = "mv-\(video.trackId)"
        busyStreamKey = key
        let played = await trendingService.playArtistTrackAdFree(
            title: video.title,
            artist: profile?.canonicalName ?? video.artistName,
            isVideo: true
        )
        busyStreamKey = nil
        if played {
            playerSheetBinding.wrappedValue = true
        }
    }

    private func saveSongOffline(_ song: ArtistTopSongItem) async {
        downloadingKeys.insert(song.id)
        _ = await trendingService.downloadArtistTrackOffline(
            title: song.title,
            artist: profile?.canonicalName ?? song.artistName,
            downloader: downloader
        )
        downloadingKeys.remove(song.id)
    }
}

// MARK: - Apple Music-Style Section Views

private struct ArtistHeroBannerView: View {
    let profile: ArtistProfileBundle
    let offlineCount: Int
    let onPlayTop: () -> Void
    let onShuffleTop: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: profile.heroImageURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    LinearGradient(
                        colors: [Color(red: 0.35, green: 0.14, blue: 0.65), Color(red: 0.85, green: 0.22, blue: 0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay {
                        Image(systemName: "music.mic")
                            .font(.system(size: 72, weight: .bold))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                }
            }
            .frame(height: 290)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.25), .black.opacity(0.84)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                if !profile.trendSources.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(profile.trendSources.prefix(3), id: \.self) { src in
                            Label(src.rawValue, systemImage: src.systemImage)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(src.badgeColor.opacity(0.9), in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }

                Text(profile.canonicalName)
                    .font(.system(size: 32, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if let g = profile.genre {
                        Text(g)
                    }
                    if let fans = profile.fanCount, fans > 0 {
                        Text("• \(Self.formattedFans(fans)) fans")
                    }
                    if !profile.albums.isEmpty || !profile.singlesAndEPs.isEmpty {
                        Text("• \(profile.albums.count + profile.singlesAndEPs.count) releases")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))

                HStack(spacing: 12) {
                    Button(action: onPlayTop) {
                        Label(offlineCount > 0 ? "Play Offline" : "Play Top Song", systemImage: "play.fill")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(.red, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Button(action: onShuffleTop) {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
    }

    private static func formattedFans(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        }
        if count >= 1_000 {
            return "\(count / 1_000)K"
        }
        return "\(count)"
    }
}

private struct LatestReleaseBannerView: View {
    let release: ArtistReleaseItem
    var showPlayerSheet: Binding<Bool>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Latest Release")
                .font(.title3.weight(.bold))

            NavigationLink {
                ArtistReleaseDetailView(release: release, showPlayerSheet: showPlayerSheet)
            } label: {
                HStack(spacing: 14) {
                    AsyncImage(url: release.artworkURL) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.secondary.opacity(0.2))
                            .overlay { Image(systemName: "opticaldisc") }
                    }
                    .frame(width: 92, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(release.releaseYearText.isEmpty ? "NEW RELEASE" : "RELEASED \(release.releaseYearText)")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.red)
                        Text(release.title)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text("\(release.isSingleOrEP ? "Single / EP" : "Album") • \(release.trackCount) \(release.trackCount == 1 ? "song" : "songs")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

private struct ArtistReleasesShelfView: View {
    let title: String
    let releases: [ArtistReleaseItem]
    var showPlayerSheet: Binding<Bool>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.title3.weight(.bold))
                Spacer()
                Text("\(releases.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(releases) { rel in
                        NavigationLink {
                            ArtistReleaseDetailView(release: rel, showPlayerSheet: showPlayerSheet)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                AsyncImage(url: rel.artworkURL) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.secondary.opacity(0.2))
                                        .overlay { Image(systemName: "square.stack") }
                                }
                                .frame(width: 146, height: 146)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                Text(rel.title)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)

                                Text(
                                    rel.releaseYearText.isEmpty
                                        ? "\(rel.trackCount) tracks"
                                        : "\(rel.releaseYearText) • \(rel.trackCount) tracks"
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            .frame(width: 146, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

private struct ArtistMusicVideosShelfView: View {
    let videos: [ArtistMusicVideoItem]
    let busyVideoID: String?
    let onPlayVideo: (ArtistMusicVideoItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Music Videos")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(videos) { mv in
                        let isBusy = busyVideoID == "mv-\(mv.trackId)"
                        Button {
                            onPlayVideo(mv)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack {
                                    AsyncImage(url: mv.artworkURL) { img in
                                        img.resizable().scaledToFill()
                                    } placeholder: {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(Color.secondary.opacity(0.25))
                                    }
                                    .frame(width: 210, height: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                    if isBusy {
                                        ProgressView()
                                            .tint(.white)
                                            .padding(10)
                                            .background(.black.opacity(0.6), in: Circle())
                                    } else {
                                        Image(systemName: "play.circle.fill")
                                            .font(.largeTitle)
                                            .foregroundStyle(.white.opacity(0.92))
                                            .shadow(radius: 4)
                                    }
                                }

                                Text(mv.title)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                if let dur = mv.durationSeconds, dur > 0 {
                                    Text(MediaTimeFormatter.format(dur))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 210, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

private struct SimilarArtistsShelfView: View {
    let artists: [SimilarArtistItem]
    var showPlayerSheet: Binding<Bool>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Similar Artists")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(artists) { sim in
                        NavigationLink {
                            ArtistProfileView(
                                artistName: sim.name,
                                seedDeezerID: sim.deezerArtistID,
                                seedImageURL: sim.imageURL,
                                showPlayerSheet: showPlayerSheet
                            )
                        } label: {
                            VStack(spacing: 8) {
                                AsyncImage(url: sim.imageURL) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: {
                                    Circle()
                                        .fill(Color.secondary.opacity(0.2))
                                        .overlay { Image(systemName: "person.fill") }
                                }
                                .frame(width: 96, height: 96)
                                .clipShape(Circle())

                                Text(sim.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(width: 100)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - Album / Single / EP Detail View

struct ArtistReleaseDetailView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(WebMediaDownloader.self) private var downloader
    @Environment(TrendingArtistsService.self) private var trendingService

    let release: ArtistReleaseItem
    var showPlayerSheet: Binding<Bool>? = nil

    @State private var tracks: [ArtistReleaseTrackItem] = []
    @State private var isLoadingTracks = true
    @State private var isSavingRelease = false
    @State private var saveProgressText = ""
    @State private var busyTrackKey: String?

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    AsyncImage(url: release.artworkURL) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.secondary.opacity(0.2))
                    }
                    .frame(width: 190, height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 14, y: 6)

                    Text(release.title)
                        .font(.title3.weight(.heavy))
                        .multilineTextAlignment(.center)

                    Text("\(release.artistName)\(release.releaseYearText.isEmpty ? "" : " • \(release.releaseYearText)")")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)

                    if let genre = release.genre {
                        Text("\(genre) • \(release.trackCount) \(release.trackCount == 1 ? "Track" : "Tracks")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await saveEntireReleaseOffline() }
                    } label: {
                        HStack {
                            if isSavingRelease {
                                ProgressView()
                                    .padding(.trailing, 4)
                                Text(saveProgressText)
                            } else {
                                Label("Save Release to Offline Playlist", systemImage: "arrow.down.circle.fill")
                            }
                        }
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isSavingRelease || tracks.isEmpty)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }

            Section("Tracklist") {
                if isLoadingTracks {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading tracks...")
                            .foregroundStyle(.secondary)
                    }
                } else if tracks.isEmpty {
                    Text("No tracklist metadata available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tracks) { track in
                        HStack(spacing: 12) {
                            Text("\(track.trackNumber)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 24)

                            Button {
                                Task {
                                    busyTrackKey = track.id
                                    _ = await trendingService.playArtistTrackAdFree(
                                        title: track.title,
                                        artist: track.artistName.isEmpty ? release.artistName : track.artistName
                                    )
                                    busyTrackKey = nil
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if let d = track.durationSeconds {
                                        Text(MediaTimeFormatter.format(d))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if busyTrackKey == track.id {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Button {
                                    Task {
                                        busyTrackKey = track.id
                                        _ = await trendingService.downloadArtistTrackOffline(
                                            title: track.title,
                                            artist: track.artistName.isEmpty ? release.artistName : track.artistName,
                                            downloader: downloader
                                        )
                                        busyTrackKey = nil
                                    }
                                } label: {
                                    Image(systemName: "arrow.down.circle")
                                        .font(.title3)
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .applyAppTheme()
        .navigationTitle(release.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: release.collectionId) {
            isLoadingTracks = true
            tracks = await trendingService.fetchReleaseTracks(collectionId: release.collectionId)
            isLoadingTracks = false
        }
    }

    private func saveEntireReleaseOffline() async {
        guard !tracks.isEmpty else { return }
        isSavingRelease = true
        let playlistName = "\(release.artistName) - \(release.title)"
        let targetPlaylist = mediaManager.createPlaylist(name: playlistName)
        var saved = 0
        for (idx, tr) in tracks.enumerated() {
            saveProgressText = "Downloading \(idx + 1)/\(tracks.count): \(tr.title)"
            let item = await trendingService.downloadArtistTrackOffline(
                title: tr.title,
                artist: tr.artistName.isEmpty ? release.artistName : tr.artistName,
                downloader: downloader,
                targetPlaylistID: targetPlaylist?.id
            )
            if item != nil { saved += 1 }
        }
        isSavingRelease = false
        saveProgressText = ""
        mediaManager.statusMessage = "Saved \(saved)/\(tracks.count) tracks to \"\(playlistName)\""
    }
}

// MARK: - Monthly Trending Artists Hub

struct TrendingArtistsHubView: View {
    @Environment(TrendingArtistsService.self) private var trendingService
    var showPlayerSheet: Binding<Bool>? = nil

    private enum FeedFilter: String, CaseIterable, Identifiable {
        case all = "All Trending"
        case newOnly = "New Artists"
        case tiktok = "TikTok"
        case instagram = "IG Reels"
        case charts = "Charts"
        var id: String { rawValue }
    }

    @State private var filter: FeedFilter = .all
    @State private var searchText = ""

    private var filteredRecords: [DiscoveredArtistRecord] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trendingService.artists.filter { rec in
            switch filter {
            case .all:
                break
            case .newOnly:
                if !rec.isNewSinceStaticCatalog { return false }
            case .tiktok:
                if !rec.trendSources.contains(.tiktok) { return false }
            case .instagram:
                if !rec.trendSources.contains(.instagram) { return false }
            case .charts:
                if !rec.trendSources.contains(.appleCharts) && !rec.trendSources.contains(.deezerCharts) { return false }
            }
            guard !trimmed.isEmpty else { return true }
            return rec.canonicalName.localizedCaseInsensitiveContains(trimmed) ||
                rec.genre.localizedCaseInsensitiveContains(trimmed) ||
                (rec.viralTrackTitle?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    var body: some View {
        @Bindable var trendingService = trendingService

        List {
            refreshStatusSection(autoToggle: $trendingService.autoMonthlyRefresh)

            Section {
                Picker("Filter", selection: $filter) {
                    ForEach(FeedFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.menu)
            }

            if filteredRecords.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No Trending Artists Yet", systemImage: "sparkles")
                    } description: {
                        Text("Tap Refresh Now to scan TikTok, Instagram Reels & Charts and build profiles.")
                    } actions: {
                        Button("Refresh Trending Now") {
                            Task { await trendingService.refreshTrendingArtists(force: true) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                Section("Trending & Discovered Profiles (\(filteredRecords.count))") {
                    ForEach(filteredRecords) { rec in
                        NavigationLink {
                            ArtistProfileView(
                                artistName: rec.canonicalName,
                                seedITunesID: rec.iTunesArtistID,
                                seedDeezerID: rec.deezerArtistID,
                                seedImageURL: rec.imageURL,
                                showPlayerSheet: showPlayerSheet
                            )
                        } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: rec.imageURL) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: {
                                    Circle()
                                        .fill(Color.pink.opacity(0.15))
                                        .overlay { Image(systemName: "person.fill").foregroundStyle(.pink) }
                                }
                                .frame(width: 50, height: 50)
                                .clipShape(Circle())

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(rec.canonicalName)
                                            .font(.subheadline.weight(.bold))
                                            .lineLimit(1)
                                        if rec.isNewSinceStaticCatalog {
                                            Text("NEW")
                                                .font(.caption2.weight(.heavy))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color.pink.opacity(0.18), in: Capsule())
                                                .foregroundStyle(.pink)
                                        }
                                    }

                                    Text(
                                        rec.viralTrackTitle.map { "Viral with: \($0) • \(rec.genre)" } ?? rec.genre
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                    HStack(spacing: 5) {
                                        ForEach(rec.trendSources.prefix(3), id: \.self) { src in
                                            Text(src.rawValue)
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(src.badgeColor.opacity(0.14), in: Capsule())
                                                .foregroundStyle(src.badgeColor)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .applyAppTheme()
        .navigationTitle("Trending Artists")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search trending artists or songs")
        .task {
            await trendingService.refreshIfDue()
        }
    }

    private func refreshStatusSection(autoToggle: Binding<Bool>) -> some View {
        Section {
            Toggle("Auto-Refresh Every Month", isOn: autoToggle)

            Button {
                Task { await trendingService.refreshTrendingArtists(force: true) }
            } label: {
                HStack {
                    if trendingService.isRefreshing {
                        ProgressView()
                            .padding(.trailing, 6)
                        Text(trendingService.lastStatusMessage ?? "Refreshing from TikTok, Reels & Charts...")
                    } else {
                        Label("Refresh Trending Artists Now", systemImage: "arrow.triangle.2.circlepath")
                            .fontWeight(.semibold)
                    }
                }
            }
            .disabled(trendingService.isRefreshing)
        } footer: {
            let lastText = trendingService.lastRefreshedAt.map {
                "Last updated \($0.formatted(date: .abbreviated, time: .shortened))."
            } ?? "Waiting for first sync."
            let nextText = trendingService.nextScheduledRefreshDate.map {
                " Next auto-refresh: \($0.formatted(date: .abbreviated, time: .omitted))."
            } ?? ""
            Text("\(lastText)\(nextText) New artists discovered on TikTok, Instagram Reels & Charts are automatically added to your Artist Database & Profiles.")
        }
    }
}
