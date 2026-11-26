import SwiftUI
import UIKit

struct ImportPlaylistSheetView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(PlaylistImportManager.self) private var playlistImportManager
    @Environment(\.dismiss) private var dismiss

    var initialURL: String? = nil
    var onPlaylistImported: ((UUID) -> Void)? = nil

    @State private var playlistURL = ""
    @State private var preferredFormat: PlaylistImportPreferredFormat = .audioOnly
    @State private var inputError: String?
    @State private var issuesJobID: IdentifiedUUID?

    init(initialURL: String? = nil, onPlaylistImported: ((UUID) -> Void)? = nil) {
        self.initialURL = initialURL
        self.onPlaylistImported = onPlaylistImported
    }

    private var parsedInput: ParsedExternalPlaylistURL? {
        PlaylistURLImporter.parsePlaylistURL(playlistURL)
    }

    var body: some View {
        NavigationStack {
            List {
                if !playlistImportManager.jobs.isEmpty {
                    activeBackgroundJobsSection
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            TextField("Paste playlist URL (YouTube, Spotify, Apple)", text: $playlistURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .onChange(of: playlistURL) { _, _ in
                                    inputError = nil
                                }

                            Button {
                                if let clip = UIPasteboard.general.string {
                                    playlistURL = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                                    inputError = nil
                                }
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.body)
                            }
                            .buttonStyle(.bordered)
                        }

                        if let parsed = parsedInput {
                            Label(parsed.platform.rawValue, systemImage: parsed.platform.systemImage)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }

                        Picker("Download As", selection: $preferredFormat) {
                            ForEach(PlaylistImportPreferredFormat.allCases) { fmt in
                                Text(fmt == .audioOnly ? "Audio" : "Video").tag(fmt)
                            }
                        }
                        .pickerStyle(.segmented)

                        if let inputError {
                            Label(inputError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        Button {
                            startDownloadAll()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.title3)
                                Text(preferredFormat == .audioOnly ? "Download All Songs" : "Download All Videos")
                                    .font(.headline.weight(.bold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(playlistURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Import Playlist")
                }
            }
            .navigationTitle("Import Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(item: $issuesJobID) { wrapped in
                ImportIssuesView(jobID: wrapped.id)
            }
            .task {
                if let initialURL, !initialURL.isEmpty, playlistURL.isEmpty {
                    playlistURL = initialURL
                }
            }
        }
    }

    // MARK: - Queue Section

    private var activeBackgroundJobsSection: some View {
        Section("Downloads") {
            ForEach(playlistImportManager.jobs.prefix(5)) { job in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.playlistName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(jobStatusSubtitle(job))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
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

                    if let discoveryError = job.discoveryError, !discoveryError.isEmpty {
                        Text(discoveryError)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }

                    HStack(spacing: 10) {
                        Text("\(job.processedCount) / \(job.totalCount)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                        if job.isDiscoveringPages {
                            Label("Finding tracks...", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Text("\(job.completedCount) saved • \(job.skippedCount) cached\(job.failedCount > 0 ? " • \(job.failedCount) failed" : "")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    ImportJobActiveTracksView(job: job)

                    ImportJobIssuesBar(job: job) {
                        issuesJobID = IdentifiedUUID(id: job.id)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Actions

    private func startDownloadAll() {
        let trimmed = playlistURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = PlaylistURLImporter.parsePlaylistURL(trimmed) else {
            inputError = PlaylistImportError.invalidURL.localizedDescription
            return
        }

        let initialPlaylistTitle = parsed.platform == .youtubeMusic
            ? "YouTube Playlist"
            : "\(parsed.platform.rawValue) Playlist"

        guard let created = mediaManager.createPlaylist(name: initialPlaylistTitle) else {
            inputError = "Could not create playlist."
            return
        }

        playlistImportManager.enqueueURLImport(
            sourceURLString: parsed.originalURL?.absoluteString ?? trimmed,
            playlistName: created.name,
            targetPlaylistID: created.id,
            preferredFormat: preferredFormat,
            alwaysUseBrowserResolver: false,
            respectMaxDurationLimit: false,
            skipDiscoveryIfComplete: false
        )

        onPlaylistImported?(created.id)
    }

    private func jobStatusSubtitle(_ job: PlaylistImportJob) -> String {
        if job.isCancelled { return "Stopped • \(job.cancelledCount) not downloaded" }
        if job.isFinished { return "Completed • \(job.preferredFormat == .audioOnly ? "Audio" : "Video")" }
        if job.isPaused { return "Paused • \(job.remainingCount) remaining" }
        return "Downloading \(job.preferredFormat == .audioOnly ? "Audio" : "Video")"
    }
}
