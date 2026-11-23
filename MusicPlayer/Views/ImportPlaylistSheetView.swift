import SwiftUI
import UIKit

private enum PlaylistImportMediaFormat: String, CaseIterable, Identifiable {
    case audio = "Audio (.m4a)"
    case video = "Video (.mp4)"

    var id: String { rawValue }
}

struct ImportPlaylistSheetView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(AppSettings.self) private var settings
    @Environment(WebMediaDownloader.self) private var downloader
    @Environment(\.dismiss) private var dismiss

    var onPlaylistImported: ((UUID) -> Void)? = nil

    @State private var playlistURL = ""
    @State private var customPlaylistName = ""
    @State private var loadedPlatform: ExternalPlaylistPlatform?
    @State private var tracks: [ExternalPlaylistTrack] = []
    @State private var preferredFormat: PlaylistImportMediaFormat = .audio
    @State private var selectedExistingPlaylistID: UUID? = nil

    @State private var isLoadingTracks = false
    @State private var isImportingTracks = false
    @State private var statusMessage = ""
    @State private var errorMessage: String?
    @State private var importedPlaylistID: UUID?
    @State private var completedCount = 0
    @State private var failedCount = 0
    @State private var currentProgressIndex = 0
    @State private var totalToImport = 0
    @State private var importTask: Task<Void, Never>?

    private var detectedPlatform: ParsedExternalPlaylistURL? {
        PlaylistURLImporter.parsePlaylistURL(playlistURL)
    }

    private var selectedTracksCount: Int {
        tracks.filter(\.isSelected).count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Paste Spotify, Apple Music, or YouTube link", text: $playlistURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .disabled(isLoadingTracks || isImportingTracks)

                    HStack(spacing: 10) {
                        Button {
                            if let clipboard = UIPasteboard.general.string {
                                playlistURL = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        } label: {
                            Label("Paste Link", systemImage: "doc.on.clipboard")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .disabled(isLoadingTracks || isImportingTracks)

                        Spacer()

                        if let detected = detectedPlatform {
                            Label(detected.platform.rawValue, systemImage: detected.platform.systemImage)
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.16), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    Button {
                        Task { await loadPlaylistTracks() }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoadingTracks {
                                ProgressView()
                                    .padding(.trailing, 6)
                                Text("Fetching Playlist...")
                            } else {
                                Label("Load Playlist Tracks", systemImage: "arrow.down.doc")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(detectedPlatform == nil || isLoadingTracks || isImportingTracks)
                } header: {
                    Text("Playlist URL")
                } footer: {
                    Text("Supports public Spotify, Apple Music, YouTube, and YouTube Music playlist links without signing in or entering API keys.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if !tracks.isEmpty {
                    Section("Destination & Format") {
                        Picker("Target Playlist", selection: $selectedExistingPlaylistID) {
                            Text("Create New Playlist").tag(UUID?.none)
                            ForEach(mediaManager.playlists) { existing in
                                Text("Add to: \(existing.name)").tag(UUID?.some(existing.id))
                            }
                        }
                        .disabled(isImportingTracks)

                        if selectedExistingPlaylistID == nil {
                            TextField("Playlist name", text: $customPlaylistName)
                                .disabled(isImportingTracks)
                        }

                        Picker("Download Format", selection: $preferredFormat) {
                            ForEach(PlaylistImportMediaFormat.allCases) { fmt in
                                Text(fmt.rawValue).tag(fmt)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(isImportingTracks)

                        if isImportingTracks {
                            VStack(alignment: .leading, spacing: 6) {
                                ProgressView(value: Double(currentProgressIndex), total: Double(max(1, totalToImport)))
                                    .progressViewStyle(.linear)
                                HStack {
                                    Text(statusMessage.isEmpty ? "Downloading tracks..." : statusMessage)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(completedCount) saved")
                                        .font(.caption.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                            }
                            .padding(.vertical, 4)

                            Button(role: .destructive) {
                                importTask?.cancel()
                                isImportingTracks = false
                                statusMessage = "Stopped after \(completedCount) saved tracks."
                            } label: {
                                Label("Stop Import", systemImage: "stop.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                startBatchImport()
                            } label: {
                                HStack {
                                    Spacer()
                                    Label(
                                        "Import & Save Offline (\(selectedTracksCount))",
                                        systemImage: "arrow.down.circle.fill"
                                    )
                                    .fontWeight(.semibold)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedTracksCount == 0)
                        }

                        if !statusMessage.isEmpty && !isImportingTracks {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(statusMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if let createdID = importedPlaylistID {
                                    Button {
                                        dismiss()
                                        onPlaylistImported?(createdID)
                                    } label: {
                                        Label("Open Imported Playlist", systemImage: "music.note.list")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }

                    Section {
                        ForEach($tracks) { $track in
                            HStack(spacing: 12) {
                                Button {
                                    if !isImportingTracks {
                                        track.isSelected.toggle()
                                    }
                                } label: {
                                    Image(systemName: track.isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(track.isSelected ? Color.accentColor : .secondary)
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        if !track.artist.isEmpty {
                                            Text(track.artist)
                                                .lineLimit(1)
                                        }
                                        if let dur = track.durationText, !dur.isEmpty {
                                            Text("• \(dur)")
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 6)

                                trackStateBadge(track.state)
                            }
                        }
                    } header: {
                        HStack {
                            Text("Tracks (\(tracks.count))")
                            Spacer()
                            if !isImportingTracks {
                                Button(selectedTracksCount == tracks.count ? "Deselect All" : "Select All") {
                                    let selectAll = selectedTracksCount != tracks.count
                                    for idx in tracks.indices {
                                        tracks[idx].isSelected = selectAll
                                    }
                                }
                                .font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
            }
            .applyAppTheme()
            .navigationTitle("Import Playlist URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isImportingTracks ? "Close" : "Done") {
                        importTask?.cancel()
                        dismiss()
                    }
                }
            }
            .onDisappear {
                importTask?.cancel()
            }
        }
    }

    @ViewBuilder
    private func trackStateBadge(_ state: PlaylistTrackImportState) -> some View {
        switch state {
        case .pending:
            EmptyView()
        case .matching, .downloading:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text(state.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
        case .failed(let reason):
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
    }

    private func loadPlaylistTracks() async {
        errorMessage = nil
        statusMessage = ""
        importedPlaylistID = nil
        isLoadingTracks = true
        defer { isLoadingTracks = false }

        do {
            let loaded = try await PlaylistURLImporter.fetchPlaylist(from: playlistURL)
            loadedPlatform = loaded.platform
            tracks = loaded.tracks
            if customPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                customPlaylistName = loaded.title
            }
            statusMessage = "Loaded \(loaded.tracks.count) tracks from \(loaded.platform.rawValue)."
        } catch {
            errorMessage = error.localizedDescription
            tracks = []
        }
    }

    private func startBatchImport() {
        let selectedIndices = tracks.indices.filter { tracks[$0].isSelected }
        guard !selectedIndices.isEmpty else { return }

        let targetPlaylistID: UUID
        if let existingID = selectedExistingPlaylistID,
           mediaManager.playlists.contains(where: { $0.id == existingID }) {
            targetPlaylistID = existingID
        } else {
            let fallbackName = customPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "\(loadedPlatform?.rawValue ?? "Imported") Playlist"
                : customPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let created = mediaManager.createPlaylist(name: fallbackName) else {
                errorMessage = "Could not create destination playlist."
                return
            }
            targetPlaylistID = created.id
        }

        importedPlaylistID = targetPlaylistID
        isImportingTracks = true
        errorMessage = nil
        completedCount = 0
        failedCount = 0
        currentProgressIndex = 0
        totalToImport = selectedIndices.count

        for idx in selectedIndices {
            tracks[idx].state = .pending
        }

        let wantAudio = (preferredFormat == .audio)
        let maxDuration = settings.maxCacheDurationMinutes

        importTask = Task {
            for (step, trackIndex) in selectedIndices.enumerated() {
                if Task.isCancelled { break }
                let track = tracks[trackIndex]
                currentProgressIndex = step
                statusMessage = "Processing \(step + 1) of \(totalToImport): \(track.title)"

                var resolvedVideoID = track.youtubeVideoID
                if resolvedVideoID == nil {
                    tracks[trackIndex].state = .matching
                    resolvedVideoID = await PlaylistURLImporter.findBestYouTubeVideoID(
                        title: track.title,
                        artist: track.artist
                    )
                }

                if Task.isCancelled { break }
                guard let vid = resolvedVideoID,
                      let watchURL = URL(string: "https://www.youtube.com/watch?v=\(vid)") else {
                    tracks[trackIndex].state = .failed("Not found")
                    failedCount += 1
                    currentProgressIndex = step + 1
                    continue
                }

                tracks[trackIndex].state = .downloading
                guard let resolved = await YouTubeStreamResolver.resolveStreams(for: watchURL),
                      !resolved.streams.isEmpty else {
                    tracks[trackIndex].state = .failed("Unavailable")
                    failedCount += 1
                    currentProgressIndex = step + 1
                    continue
                }

                let preferredStreams: [DetectedBrowserMedia]
                if wantAudio {
                    let audioStreams = resolved.streams.filter { $0.isAudio }
                    let nonHLSFallback = resolved.streams.filter { !$0.isHLS && !$0.isAudio }
                    preferredStreams = audioStreams.isEmpty ? nonHLSFallback : (audioStreams + nonHLSFallback)
                } else {
                    let videoStreams = resolved.streams.filter { !$0.isAudio && !$0.isHLS }
                    let audioFallback = resolved.streams.filter { $0.isAudio }
                    preferredStreams = videoStreams.isEmpty ? audioFallback : (videoStreams + audioFallback)
                }

                guard let primary = preferredStreams.first else {
                    tracks[trackIndex].state = .failed("No stream")
                    failedCount += 1
                    currentProgressIndex = step + 1
                    continue
                }

                let taggedPrimary = DetectedBrowserMedia(
                    url: primary.url,
                    pairedAudioURL: primary.pairedAudioURL,
                    isHLS: primary.isHLS,
                    isAudio: primary.isAudio,
                    title: track.title,
                    author: track.artist.isEmpty ? resolved.author : track.artist,
                    qualityLabel: primary.qualityLabel,
                    referer: primary.referer,
                    customHeaders: primary.customHeaders,
                    durationSeconds: resolved.durationSeconds ?? primary.durationSeconds,
                    isActivelyPlaying: false
                )

                if await downloader.downloadTrackIntoPlaylist(
                    taggedPrimary,
                    fallbackStreams: Array(preferredStreams.dropFirst()),
                    targetPlaylistID: targetPlaylistID,
                    maxDurationMinutes: maxDuration
                ) != nil {
                    tracks[trackIndex].state = .saved
                    completedCount += 1
                } else {
                    tracks[trackIndex].state = .failed("Failed")
                    failedCount += 1
                }

                currentProgressIndex = step + 1
            }

            isImportingTracks = false
            if failedCount > 0 {
                statusMessage = "Imported \(completedCount) of \(totalToImport) tracks (\(failedCount) skipped)."
            } else {
                statusMessage = "Imported all \(completedCount) tracks for offline playback!"
            }
        }
    }
}
