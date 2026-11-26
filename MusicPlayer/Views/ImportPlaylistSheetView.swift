import SwiftUI
import UIKit

struct ImportPlaylistSheetView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(AppSettings.self) private var settings
    @Environment(BrowserStore.self) private var browserStore
    @Environment(PlaylistImportManager.self) private var playlistImportManager
    @Environment(\.dismiss) private var dismiss

    var initialURL: String? = nil
    var onPlaylistImported: ((UUID) -> Void)? = nil

    @State private var playlistURL = ""
    @State private var newPlaylistName = ""
    @State private var destinationMode = 0 // 0 = New Playlist, 1 = Existing Playlist
    @State private var selectedPlaylistID: UUID?

    @State private var preferredFormat: PlaylistImportPreferredFormat = .audioOnly
    @State private var alwaysUseBrowserResolver = false
    @State private var respectMaxDurationLimit = false

    @State private var isLoadingPlaylist = false
    @State private var loadedPagesCount = 0
    @State private var fetchError: String?
    @State private var loadedPlatform: ExternalPlaylistPlatform?
    @State private var tracks: [ExternalPlaylistTrack] = []
    @State private var deselectedIDs: Set<UUID> = []
    @State private var trackSearchQuery = ""
    @State private var visibleTrackLimit = 200

    @State private var fetchTask: Task<Void, Never>?
    @State private var handoffBox = DiscoveryHandoffBox()
    @State private var startedJobID: UUID?
    @State private var showingBuiltInBrowser = false
    @State private var issuesJobID: IdentifiedUUID?

    init(initialURL: String? = nil, onPlaylistImported: ((UUID) -> Void)? = nil) {
        self.initialURL = initialURL
        self.onPlaylistImported = onPlaylistImported
    }

    @MainActor
    private final class DiscoveryHandoffBox {
        var adoptedJobID: UUID?
        var includeFuturePages = true
    }

    private var detectedPlatform: ExternalPlaylistPlatform? {
        PlaylistURLImporter.parsePlaylistURL(playlistURL)?.platform
    }

    private var selectedTracks: [ExternalPlaylistTrack] {
        tracks.filter { !deselectedIDs.contains($0.id) }
    }

    private var selectedCount: Int {
        max(0, tracks.count - deselectedIDs.count)
    }

    private var filteredTracks: [ExternalPlaylistTrack] {
        let q = trackSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
        }
    }

    private var visibleTracks: ArraySlice<ExternalPlaylistTrack> {
        let list = filteredTracks
        if list.count <= visibleTrackLimit {
            return list[...]
        }
        return list.prefix(visibleTrackLimit)
    }

    private var canStartImport: Bool {
        guard !tracks.isEmpty, selectedCount > 0 else { return false }
        if destinationMode == 1 {
            return selectedPlaylistID != nil
        }
        return !newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if !playlistImportManager.jobs.isEmpty {
                    activeBackgroundJobsSection
                }

                urlInputSection

                if !tracks.isEmpty {
                    destinationAndOptionsSection
                    startBackgroundButtonSection
                    tracksPreviewSection
                } else if let fetchError {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(fetchError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                            Button {
                                openPlaylistInBuiltInBrowser()
                            } label: {
                                Label("Open in Built-in Browser Instead", systemImage: "safari")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Import Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        // Only cancel URL discovery if the user has NOT started a background job;
                        // active background downloads always keep running cleanly after dismissal.
                        if handoffBox.adoptedJobID == nil {
                            fetchTask?.cancel()
                        }
                        dismiss()
                    }
                }
            }
            .onDisappear {
                if handoffBox.adoptedJobID == nil {
                    fetchTask?.cancel()
                }
            }
            .sheet(isPresented: $showingBuiltInBrowser) {
                BrowserTabView(showPlayerSheet: .constant(false), isModal: true)
            }
            .sheet(item: $issuesJobID) { wrapped in
                ImportIssuesView(jobID: wrapped.id)
            }
            .task {
                if selectedPlaylistID == nil {
                    selectedPlaylistID = mediaManager.playlists.first?.id
                }
                if let initialURL, !initialURL.isEmpty, playlistURL.isEmpty {
                    playlistURL = initialURL
                    fetchPlaylistMetadata()
                }
            }
        }
    }

    // MARK: - Sections

    private var activeBackgroundJobsSection: some View {
        Section("Background Download Queue") {
            ForEach(playlistImportManager.jobs.prefix(5)) { job in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.playlistName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(jobStatusSubtitle(job))
                                .font(.caption2)
                                .foregroundStyle(job.isCancelled ? .secondary : .secondary)
                        }
                        Spacer()
                        if !job.isFinished {
                            if job.isPaused {
                                Button("Resume") {
                                    playlistImportManager.resumeJob(id: job.id)
                                }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            } else {
                                Button("Pause") {
                                    playlistImportManager.pauseJob(id: job.id)
                                }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            Button(role: .destructive) {
                                playlistImportManager.cancelJob(id: job.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                        } else {
                            if job.canRetry {
                                Button(job.failedCount > 0 ? "Retry (\(job.failedCount))" : "Restart") {
                                    playlistImportManager.retryFailedTracks(inJobID: job.id)
                                }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            Button("Clear") {
                                playlistImportManager.clearFinishedJob(id: job.id)
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                        }
                    }

                    ProgressView(value: job.progressFraction)
                        .progressViewStyle(.linear)
                        .tint(job.isFinished && job.failedCount == 0 ? .green : .accentColor)

                    HStack(spacing: 10) {
                        Text("\(job.processedCount) / \(job.totalCount)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                        if job.isDiscoveringPages {
                            Label("Discovering pages...", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Text("\(job.completedCount) saved • \(job.skippedCount) cached\(job.failedCount > 0 ? " • \(job.failedCount) failed" : "")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    ImportJobIssuesBar(job: job) {
                        issuesJobID = IdentifiedUUID(id: job.id)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var urlInputSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Paste YouTube / YT Music / Spotify / Apple URL", text: $playlistURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    Button {
                        if let clip = UIPasteboard.general.string {
                            playlistURL = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.body)
                    }
                    .buttonStyle(.bordered)
                }

                HStack {
                    if let platform = detectedPlatform {
                        Label(platform.rawValue, systemImage: platform.systemImage)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Supports huge playlists (5,000+ songs, no limit)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if PlaylistURLImporter.parsePlaylistURL(playlistURL)?.platform == .youtubeMusic {
                        Button("Open in Browser") {
                            openPlaylistInBuiltInBrowser()
                        }
                        .font(.caption.weight(.medium))
                        .buttonStyle(.borderless)
                    }
                }

                Button {
                    fetchPlaylistMetadata()
                } label: {
                    HStack {
                        if isLoadingPlaylist {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                        Text(isLoadingPlaylist
                             ? "Loading Page \(max(1, loadedPagesCount)) (\(tracks.count) found, no limit)..."
                             : "Find Playlist Tracks")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(playlistURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Playlist Link")
        } footer: {
            Text("YouTube playlist videos are found and cached through the built-in browser engine & InnerTube with no 100-song cap. Background downloads keep running even if you close this screen.")
        }
    }

    private var destinationAndOptionsSection: some View {
        Section("Destination & Browser Options") {
            Picker("Save To", selection: $destinationMode) {
                Text("New Playlist").tag(0)
                if !mediaManager.playlists.isEmpty {
                    Text("Existing Playlist").tag(1)
                }
            }
            .pickerStyle(.segmented)

            if destinationMode == 0 {
                TextField("Playlist Name", text: $newPlaylistName)
            } else {
                Picker("Playlist", selection: $selectedPlaylistID) {
                    ForEach(mediaManager.playlists) { pl in
                        Text(pl.name).tag(Optional(pl.id))
                    }
                }
            }

            Picker("Format", selection: $preferredFormat) {
                ForEach(PlaylistImportPreferredFormat.allCases) { fmt in
                    Text(fmt.displayTitle).tag(fmt)
                }
            }
            .pickerStyle(.segmented)

            Text(preferredFormat.shortSubtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle(isOn: $alwaysUseBrowserResolver) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Always Resolve via Built-in Browser")
                        .font(.subheadline)
                    Text("When off, fast API runs first with automatic Built-in Browser fallback for every track.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $respectMaxDurationLimit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skip Tracks Longer Than Max Duration Setting")
                        .font(.subheadline)
                    Text("Leave off to cache long mixes and full concerts too.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var startBackgroundButtonSection: some View {
        Section {
            Button {
                startBackgroundImport()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isLoadingPlaylist
                             ? "Start Background Download Now (\(selectedCount)+ queued)"
                             : "Download & Add All \(selectedCount) Tracks to Playlist")
                            .font(.subheadline.weight(.bold))
                        Text("Runs in background — safe to close sheet or switch apps")
                            .font(.caption2)
                            .opacity(0.85)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStartImport || startedJobID != nil)
        }
    }

    private var tracksPreviewSection: some View {
        Section {
            TextField("Filter \(tracks.count) tracks by title or artist", text: $trackSearchQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            HStack {
                Text("\(selectedCount) of \(tracks.count) selected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if isLoadingPlaylist {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Streaming more...")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button(deselectedIDs.isEmpty ? "Deselect All" : "Select All") {
                    if deselectedIDs.isEmpty {
                        deselectedIDs = Set(tracks.map(\.id))
                    } else {
                        deselectedIDs.removeAll()
                    }
                }
                .font(.caption.weight(.semibold))
            }

            ForEach(visibleTracks) { track in
                let isSelected = !deselectedIDs.contains(track.id)
                HStack(spacing: 10) {
                    Button {
                        if isSelected {
                            deselectedIDs.insert(track.id)
                        } else {
                            deselectedIDs.remove(track.id)
                        }
                    } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(track.artist.isEmpty ? "Unknown Artist" : track.artist)
                            if let dur = track.durationText, !dur.isEmpty {
                                Text("• \(dur)")
                            }
                            if let vid = track.youtubeVideoID, !vid.isEmpty {
                                Text("• YT")
                                    .foregroundStyle(.green)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }

            if filteredTracks.count > visibleTrackLimit {
                HStack {
                    Text("Showing \(visibleTracks.count) of \(filteredTracks.count) tracks")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show +500 More") {
                        visibleTrackLimit += 500
                    }
                    .font(.caption.weight(.semibold))
                }
            }
        } header: {
            Text("Discovered Tracks (\(tracks.count)\(isLoadingPlaylist ? "+" : ""))")
        }
    }

    // MARK: - Actions

    private func openPlaylistInBuiltInBrowser() {
        let trimmed = playlistURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        browserStore.openInActiveTab(urlString: trimmed, title: "YouTube Playlist")
        showingBuiltInBrowser = true
    }

    private func fetchPlaylistMetadata() {
        fetchTask?.cancel()
        fetchError = nil
        tracks = []
        deselectedIDs.removeAll()
        loadedPagesCount = 0
        visibleTrackLimit = 200
        startedJobID = nil
        handoffBox = DiscoveryHandoffBox()
        isLoadingPlaylist = true

        let targetURL = playlistURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let box = handoffBox
        let manager = playlistImportManager

        fetchTask = Task {
            do {
                let cookies = await BrowserYouTubeResolver.youtubeCookieHeader()
                let parsed = PlaylistURLImporter.parsePlaylistURL(targetURL)

                do {
                    _ = try await PlaylistURLImporter.streamPlaylist(from: targetURL, cookiesHeader: cookies) { page in
                        await MainActor.run {
                            applyStreamedPage(page, handoff: box, manager: manager)
                        }
                    }
                } catch {
                    // Browser WKWebView fallback when API/anonymous HTML is blocked or private
                    if let url = URL(string: targetURL),
                       parsed?.platform == .youtubeMusic,
                       let browserData = await BrowserYouTubeResolver.shared.extractPlaylistInitialDataInBrowser(url: url),
                       let listID = parsed?.playlistID {
                        _ = try await PlaylistURLImporter.continueYouTubePlaylist(
                            fromInitialJSON: browserData.json,
                            listID: listID,
                            cookiesHeader: browserData.cookiesHeader ?? cookies
                        ) { page in
                            await MainActor.run {
                                applyStreamedPage(page, handoff: box, manager: manager)
                            }
                        }
                    } else {
                        throw error
                    }
                }

                await MainActor.run {
                    isLoadingPlaylist = false
                    if let jobID = box.adoptedJobID {
                        manager.appendDiscoveredTracks([], toJobID: jobID, isComplete: true)
                    }
                }
            } catch is CancellationError {
                await MainActor.run { isLoadingPlaylist = false }
            } catch {
                await MainActor.run {
                    isLoadingPlaylist = false
                    if tracks.isEmpty {
                        fetchError = error.localizedDescription
                    }
                    if let jobID = box.adoptedJobID {
                        manager.markDiscoveryFailed(jobID: jobID, message: error.localizedDescription)
                    }
                }
            }
        }
    }

    @MainActor
    private func applyStreamedPage(
        _ page: PlaylistURLImporter.PlaylistStreamPage,
        handoff: DiscoveryHandoffBox,
        manager: PlaylistImportManager
    ) {
        loadedPlatform = page.platform
        loadedPagesCount = max(loadedPagesCount, page.pageNumber)
        if newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            newPlaylistName = page.playlistTitle
        }
        if !page.newTracks.isEmpty {
            tracks.append(contentsOf: page.newTracks)
        }
        if let jobID = handoff.adoptedJobID {
            let tracksForQueue = handoff.includeFuturePages ? page.newTracks : []
            manager.appendDiscoveredTracks(tracksForQueue, toJobID: jobID, isComplete: page.isComplete)
        }
    }

    private func startBackgroundImport() {
        let targetPlaylistID: UUID
        let finalPlaylistName: String

        if destinationMode == 1, let existingID = selectedPlaylistID,
           let existing = mediaManager.playlists.first(where: { $0.id == existingID }) {
            targetPlaylistID = existingID
            finalPlaylistName = existing.name
        } else {
            let desiredName = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !desiredName.isEmpty,
                  let created = mediaManager.createPlaylist(name: desiredName) else {
                return
            }
            targetPlaylistID = created.id
            finalPlaylistName = created.name
        }

        let initialSelected = selectedTracks
        let stillStreaming = isLoadingPlaylist
        handoffBox.includeFuturePages = (deselectedIDs.count < tracks.count)

        let jobID = playlistImportManager.enqueueURLImport(
            sourceURLString: playlistURL.trimmingCharacters(in: .whitespacesAndNewlines),
            playlistName: finalPlaylistName,
            targetPlaylistID: targetPlaylistID,
            preferredFormat: preferredFormat,
            alwaysUseBrowserResolver: alwaysUseBrowserResolver,
            respectMaxDurationLimit: respectMaxDurationLimit,
            alreadyDiscoveredTracks: initialSelected,
            skipDiscoveryIfComplete: true,
            // If the user hand-picked tracks, a restarted discovery must not re-add the ones they removed.
            allowsRediscovery: deselectedIDs.isEmpty
        )

        if stillStreaming {
            // Keep discovery flagged active while fetchTask continues feeding future pages into jobID!
            if let idx = playlistImportManager.jobs.firstIndex(where: { $0.id == jobID }) {
                playlistImportManager.jobs[idx].isDiscoveringPages = true
                playlistImportManager.jobs[idx].discoveryCompleted = false
            }
            handoffBox.adoptedJobID = jobID
        }

        startedJobID = jobID
        onPlaylistImported?(targetPlaylistID)
    }

    private func jobStatusSubtitle(_ job: PlaylistImportJob) -> String {
        if job.isCancelled { return "Stopped • \(job.cancelledCount) not downloaded" }
        if job.isFinished { return "Completed • \(job.preferredFormat.displayTitle)" }
        if job.isPaused { return "Paused • \(job.remainingCount) remaining" }
        let suffix = job.alwaysUseBrowserResolver ? "Built-in Browser" : "Browser + API"
        return "Downloading in background (\(suffix))"
    }
}
