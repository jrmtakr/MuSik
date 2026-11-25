import SwiftUI

struct VerifyTrackArtistSheet: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(ListeningWrappedService.self) private var wrapped
    @Environment(\.dismiss) private var dismiss

    let item: MediaItem
    var onConfirmed: ((String, String) -> Void)? = nil

    @State private var searchQuery: String
    @State private var customArtistInput: String = ""
    @State private var isSearching = false
    @State private var isListeningVocals = false
    @State private var hasRunInitialSearch = false
    @State private var verificationResult: TrackVerificationResult?
    @State private var vocalTranscript: String?
    @State private var vocalErrorMessage: String?
    @State private var applyCleanTitle = true
    @State private var saveCoverArtIfMissing = true

    init(item: MediaItem, onConfirmed: ((String, String) -> Void)? = nil) {
        self.item = item
        self.onConfirmed = onConfirmed
        let cleaned = ArtistDatabase.cleanSongTitleForSearch(
            rawTitle: item.displayTitle,
            rawArtistTag: item.artist,
            ignoredChannels: ListeningWrappedService.shared.ignoredChannels
        )
        let seed = cleaned.songOnly.isEmpty ? item.displayTitle : cleaned.songOnly
        self._searchQuery = State(initialValue: seed)
    }

    private var liveItem: MediaItem {
        mediaManager.items.first(where: { $0.relativePath == item.relativePath }) ?? item
    }

    private var assessment: (artist: String, genre: String?, reason: WrappedAuditReason?, isVerified: Bool) {
        wrapped.assessItem(liveItem, metadataByPath: mediaManager.customMetadataByPath)
    }

    private var isPlayingThis: Bool {
        mediaManager.currentItem?.relativePath == liveItem.relativePath && mediaManager.isPlaying
    }

    var body: some View {
        NavigationStack {
            List {
                trackHeaderSection
                lookupToolsSection
                candidatesSection
                channelAndManualSection
            }
            .listStyle(.insetGrouped)
            .applyAppTheme()
            .navigationTitle("Confirm Song & Artist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if !hasRunInitialSearch {
                    hasRunInitialSearch = true
                    Task { await runVerificationLookup() }
                }
            }
        }
    }

    // MARK: - Sections

    private var trackHeaderSection: some View {
        Section {
            HStack(spacing: 12) {
                MediaArtworkView(
                    item: liveItem,
                    image: mediaManager.thumbnails[liveItem.relativePath],
                    cornerRadius: 10,
                    iconSize: 20
                )
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 3) {
                    Text(liveItem.displayTitle)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(2)

                    HStack(spacing: 5) {
                        Text(assessment.artist)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(assessment.isVerified ? .green : .secondary)
                        if assessment.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        } else if let reason = assessment.reason {
                            Text("(\(reason.rawValue))")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }

                    if let dur = liveItem.formattedDuration {
                        Text("File length: \(dur)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    if mediaManager.currentItem?.relativePath == liveItem.relativePath {
                        mediaManager.togglePlayPause()
                    } else {
                        mediaManager.play(liveItem)
                    }
                } label: {
                    Image(systemName: isPlayingThis ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
        }
    }

    private var lookupToolsSection: some View {
        Section {
            HStack(spacing: 8) {
                TextField("Song title or lyrics phrase", text: $searchQuery)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await runVerificationLookup() }
                    }

                Button {
                    Task { await runVerificationLookup() }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline.weight(.bold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSearching || searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button {
                Task { await runVocalClipScan() }
            } label: {
                HStack {
                    if isListeningVocals {
                        ProgressView()
                            .padding(.trailing, 4)
                        Text("Listening to vocal chorus...")
                    } else {
                        Label("Match by Hearing Song Vocals", systemImage: "waveform")
                    }
                }
                .font(.subheadline.weight(.semibold))
            }
            .disabled(isListeningVocals)

            Toggle("Also clean up Song Title when confirming", isOn: $applyCleanTitle)
            if mediaManager.thumbnails[liveItem.relativePath] == nil {
                Toggle("Save Album Art if missing", isOn: $saveCoverArtIfMissing)
            }
        } header: {
            Text("Lookup & Lyrics Match")
        } footer: {
            if let transcript = vocalTranscript, !transcript.isEmpty {
                Text("Heard vocals: \"\(transcript)\"")
            } else if let vocalErrorMessage {
                Text(vocalErrorMessage)
                    .foregroundStyle(.orange)
            } else if let ytCap = verificationResult?.youtubeCaptionSnippet {
                Text("Found YouTube lyrics caption: \"\(ytCap)\"")
            }
        }
    }

    private var candidatesSection: some View {
        Section("Suggested Artist + Lyrics Matches") {
            if isSearching {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking catalog, duration & lyrics...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else if let candidates = verificationResult?.candidates, !candidates.isEmpty {
                ForEach(candidates) { cand in
                    CandidateVerificationCardRow(
                        candidate: cand,
                        localDuration: liveItem.durationSeconds
                    ) {
                        confirmCandidate(cand)
                    }
                }
            } else {
                Text("No matches found yet. Edit the song title above or enter a chorus line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var channelAndManualSection: some View {
        Section("Confirm Artist & Channel Filtering") {
            let normArtist = ArtistDatabase.normalizeLookupKey(assessment.artist)
            if !assessment.isVerified && !normArtist.isEmpty && normArtist != "unknown artist" {
                Button {
                    let cleanTitle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    mediaManager.confirmVerifiedArtist(
                        for: liveItem,
                        artistName: assessment.artist,
                        updatedTitle: (applyCleanTitle && !cleanTitle.isEmpty) ? cleanTitle : nil,
                        genre: assessment.genre
                    )
                    onConfirmed?(ArtistDatabase.canonicalizeSingle(assessment.artist), liveItem.displayTitle)
                    dismiss()
                } label: {
                    Label("Confirm \"\(assessment.artist)\" as Real Artist", systemImage: "checkmark.seal.fill")
                        .fontWeight(.semibold)
                        .foregroundStyle(.green)
                }

                Button(role: .destructive) {
                    _ = wrapped.markAsUploaderChannel(
                        assessment.artist,
                        libraryItems: mediaManager.items,
                        metadataByPath: mediaManager.customMetadataByPath
                    )
                    let updatedCleaned = ArtistDatabase.cleanSongTitleForSearch(
                        rawTitle: liveItem.displayTitle,
                        rawArtistTag: liveItem.artist,
                        ignoredChannels: wrapped.ignoredChannels
                    )
                    if !updatedCleaned.songOnly.isEmpty {
                        searchQuery = updatedCleaned.songOnly
                    }
                    Task { await runVerificationLookup() }
                } label: {
                    Label("Treat \"\(assessment.artist)\" as Uploader Channel", systemImage: "tv.slash")
                }
            }

            HStack {
                TextField("Type real artist name", text: $customArtistInput)
                Button("Verify") {
                    let clean = customArtistInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { return }
                    mediaManager.confirmVerifiedArtist(for: liveItem, artistName: clean)
                    onConfirmed?(ArtistDatabase.canonicalizeSingle(clean), liveItem.displayTitle)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(customArtistInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Actions

    private func runVerificationLookup() async {
        isSearching = true
        vocalErrorMessage = nil
        let result = await TrackVerificationService.verifyTrack(
            rawTitle: searchQuery,
            rawArtist: nil,
            localDuration: liveItem.durationSeconds,
            sourceVideoID: mediaManager.sourceVideoID(for: liveItem),
            extraLyricSnippet: vocalTranscript,
            ignoredChannels: wrapped.ignoredChannels
        )
        verificationResult = result
        isSearching = false
    }

    private func runVocalClipScan() async {
        isListeningVocals = true
        vocalErrorMessage = nil

        if mediaManager.currentItem?.relativePath == liveItem.relativePath {
            let liveCapture = await LiveAudioLyricsAI.capturePlaybackTranscript(
                for: liveItem,
                playbackTime: mediaManager.currentTime,
                equalizerPlayer: mediaManager.equalizerPlayer,
                isEQPlaying: mediaManager.equalizerPlayer.isPlaying,
                playbackRate: mediaManager.playbackRate
            )
            if !liveCapture.transcript.isEmpty {
                vocalTranscript = liveCapture.transcript
                let result = await TrackVerificationService.verifyTrack(
                    rawTitle: searchQuery,
                    rawArtist: liveItem.artist,
                    localDuration: liveItem.durationSeconds,
                    sourceVideoID: mediaManager.sourceVideoID(for: liveItem),
                    extraLyricSnippet: liveCapture.transcript,
                    ignoredChannels: wrapped.ignoredChannels
                )
                verificationResult = result
                isListeningVocals = false
                return
            }
        }

        let scan = await TrackVerificationService.identifyFromVocalClip(
            audioURL: liveItem.fileURL,
            durationSeconds: liveItem.durationSeconds,
            titleHint: searchQuery,
            rawArtist: liveItem.artist,
            sourceVideoID: mediaManager.sourceVideoID(for: liveItem),
            ignoredChannels: wrapped.ignoredChannels
        )
        isListeningVocals = false
        if let err = scan.errorMessage {
            vocalErrorMessage = err
        }
        if let transcript = scan.transcript {
            vocalTranscript = transcript
        }
        if let verification = scan.verification {
            verificationResult = verification
        }
    }

    private func confirmCandidate(_ cand: TrackVerificationCandidate) {
        let finalTitle = applyCleanTitle ? cand.trackTitle : liveItem.displayTitle
        mediaManager.confirmVerifiedArtist(
            for: liveItem,
            artistName: cand.artistName,
            updatedTitle: applyCleanTitle ? cand.trackTitle : nil,
            genre: cand.genre
        )

        if saveCoverArtIfMissing,
           mediaManager.thumbnails[liveItem.relativePath] == nil,
           let artURL = cand.artworkURL {
            let capturedItem = liveItem
            Task {
                if let (data, _) = try? await URLSession.shared.data(from: artURL),
                   let image = UIImage(data: data) {
                    await MainActor.run {
                        mediaManager.updateTrackInfo(
                            for: capturedItem,
                            title: finalTitle,
                            artist: cand.artistName,
                            coverImage: image,
                            markArtistVerified: true,
                            genre: cand.genre
                        )
                    }
                }
            }
        }

        onConfirmed?(cand.artistName, finalTitle)
        dismiss()
    }
}

private struct CandidateVerificationCardRow: View {
    let candidate: TrackVerificationCandidate
    let localDuration: Double?
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                AsyncImage(url: candidate.artworkURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .overlay {
                            Image(systemName: "music.note")
                                .foregroundStyle(Color.accentColor)
                        }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.artistName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(candidate.trackTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Text(candidate.confidenceLabel)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(candidate.confidenceColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(candidate.confidenceColor)

                        if let d = candidate.durationSeconds {
                            Text(MediaTimeFormatter.format(d))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(durationBadgeColor(candidateDuration: d))
                        }

                        if let g = candidate.genre {
                            Text(g)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                Button("Confirm", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .font(.caption.weight(.bold))
            }

            if !candidate.matchReasons.isEmpty {
                Text(candidate.matchReasons.joined(separator: " • ") + " (\(candidate.sources.joined(separator: ", ")))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let snippet = candidate.lyricsSnippet, !snippet.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Lyrics Preview", systemImage: "text.quote")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.purple)
                    Text(snippet)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.vertical, 4)
    }

    private func durationBadgeColor(candidateDuration: Double) -> Color {
        guard let localDuration else { return .secondary }
        return abs(localDuration - candidateDuration) <= 8.0 ? .green : .orange
    }
}

// MARK: - Wrapped Audit Queue

struct WrappedAuditQueueView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(ListeningWrappedService.self) private var wrapped

    @State private var isBatchScanning = false
    @State private var scanProgressText = ""
    @State private var suggestedMatches: [String: TrackVerificationCandidate] = [:]
    @State private var sheetItem: MediaItem?

    private var auditList: [WrappedAuditItem] {
        _ = wrapped.lastUpdatedTick
        return wrapped.auditItems(
            libraryItems: mediaManager.items,
            metadataByPath: mediaManager.customMetadataByPath
        )
    }

    private var highConfidencePairs: [(item: MediaItem, match: TrackVerificationCandidate)] {
        auditList.compactMap { entry in
            guard let cand = suggestedMatches[entry.id], cand.score >= 80 else { return nil }
            return (entry.item, cand)
        }
    }

    var body: some View {
        List {
            controlsSection
            pendingTracksSection
            ignoredChannelsSection
        }
        .listStyle(.insetGrouped)
        .applyAppTheme()
        .navigationTitle("Confirm Artists")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheetItem) { target in
            VerifyTrackArtistSheet(item: target)
        }
    }

    private var controlsSection: some View {
        Section {
            if auditList.isEmpty {
                Label("All music tracks are verified or matched cleanly!", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Button {
                    Task { await autoScanTopTracks() }
                } label: {
                    HStack {
                        if isBatchScanning {
                            ProgressView()
                                .padding(.trailing, 6)
                            Text(scanProgressText)
                        } else {
                            Label("Auto-Verify Top \(min(15, auditList.count)) Tracks (Lyrics & Length)", systemImage: "sparkles")
                                .fontWeight(.semibold)
                        }
                    }
                }
                .disabled(isBatchScanning)

                if !highConfidencePairs.isEmpty {
                    Button {
                        for pair in highConfidencePairs {
                            mediaManager.confirmVerifiedArtist(
                                for: pair.item,
                                artistName: pair.match.artistName,
                                updatedTitle: pair.match.trackTitle,
                                genre: pair.match.genre
                            )
                            suggestedMatches.removeValue(forKey: pair.item.relativePath)
                        }
                    } label: {
                        Label("Approve All \(highConfidencePairs.count) High-Confidence Matches", systemImage: "checkmark.circle.fill")
                            .fontWeight(.semibold)
                            .foregroundStyle(.green)
                    }
                }
            }
        } footer: {
            Text("Flags songs with channel uploader names, missing tags, or unconfirmed artists so Wrapped gives accurate artist credit retroactively.")
        }
    }

    @ViewBuilder
    private var pendingTracksSection: some View {
        if !auditList.isEmpty {
            Section("Needs Confirmation (\(auditList.count))") {
                ForEach(auditList) { entry in
                    AuditTrackRowView(
                        entry: entry,
                        suggestedMatch: suggestedMatches[entry.id],
                        onInspect: { sheetItem = entry.item },
                        onApproveSuggestion: { match in
                            mediaManager.confirmVerifiedArtist(
                                for: entry.item,
                                artistName: match.artistName,
                                updatedTitle: match.trackTitle,
                                genre: match.genre
                            )
                            suggestedMatches.removeValue(forKey: entry.id)
                        },
                        onConfirmDetectedArtist: entry.reason == .uncataloguedArtist ? {
                            mediaManager.confirmVerifiedArtist(
                                for: entry.item,
                                artistName: entry.detectedArtist,
                                genre: entry.detectedGenre
                            )
                        } : nil
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var ignoredChannelsSection: some View {
        let ignored = Array(wrapped.ignoredChannels).sorted()
        if !ignored.isEmpty {
            Section("Ignored Uploader Channels") {
                ForEach(ignored, id: \.self) { ch in
                    HStack {
                        Label(ch, systemImage: "tv.slash")
                            .font(.subheadline)
                        Spacer()
                        Button("Restore") {
                            wrapped.removeIgnoredChannel(ch)
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
            }
        }
    }

    private func autoScanTopTracks() async {
        isBatchScanning = true
        let batch = Array(auditList.prefix(15))
        for (idx, entry) in batch.enumerated() {
            scanProgressText = "Checking \(idx + 1)/\(batch.count): \(entry.item.displayTitle)"
            let res = await TrackVerificationService.verifyTrack(
                rawTitle: entry.item.displayTitle,
                rawArtist: entry.item.artist,
                localDuration: entry.item.durationSeconds,
                sourceVideoID: mediaManager.sourceVideoID(for: entry.item),
                ignoredChannels: wrapped.ignoredChannels
            )
            if let top = res.candidates.first, top.score >= 55 {
                suggestedMatches[entry.id] = top
            }
        }
        isBatchScanning = false
        scanProgressText = ""
    }
}

private struct AuditTrackRowView: View {
    let entry: WrappedAuditItem
    let suggestedMatch: TrackVerificationCandidate?
    let onInspect: () -> Void
    let onApproveSuggestion: (TrackVerificationCandidate) -> Void
    let onConfirmDetectedArtist: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: onInspect) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.item.displayTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            HStack(spacing: 6) {
                                Text(entry.detectedArtist)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.orange)
                                Text("•")
                                Text(entry.reason.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if entry.trackedSeconds > 0 {
                                    Text("• \(ListeningWrappedService.formatHoursMinutes(entry.trackedSeconds))")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.purple)
                                }
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)

                if let onConfirmDetectedArtist, suggestedMatch == nil {
                    Button("Confirm", action: onConfirmDetectedArtist)
                        .buttonStyle(.bordered)
                        .tint(.green)
                        .font(.caption2.weight(.bold))
                }
            }

            if let match = suggestedMatch {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suggested: \(match.artistName) — \(match.trackTitle)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.green)
                            .lineLimit(1)
                        if let snippet = match.lyricsSnippet {
                            Text(snippet)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button("Confirm ✓") {
                        onApproveSuggestion(match)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .font(.caption2.weight(.bold))
                }
                .padding(8)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.vertical, 2)
    }
}
