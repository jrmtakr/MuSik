import AVFoundation
import Foundation
import Observation
@preconcurrency import Speech
import UIKit

struct WholeSongAIResult: Codable, Hashable, Sendable {
    let relativePath: String
    var completedFullListen: Bool
    var identifiedTitle: String?
    var identifiedAlbum: String?
    var identifiedArtist: String?
    var identifiedGenre: String?
    var confidenceScore: Int
    var heardWordCount: Int
    var heardExcerpt: String?
    var generatedLyricsAvailable: Bool
    var analyzedAt: Date
}

@MainActor
@Observable
final class WholeSongAIService {
    static let shared = WholeSongAIService()

    var activeTrackPath: String?
    var progressFraction: Double = 0
    var statusMessage: String?
    var lastError: String?
    var resultsByPath: [String: WholeSongAIResult] = [:]

    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSaveTask: Task<Void, Never>?

    private struct TimedHeardWord: Sendable {
        let text: String
        let startTime: Double
        let endTime: Double
    }

    private struct ChunkTranscription: Sendable {
        let words: [TimedHeardWord]
        let formattedText: String
    }

    private static var stateFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("whole_song_ai_state.json")
    }

    private init() {
        loadFromDisk()
    }

    // MARK: - Public Query & Trigger APIs

    func isListening(to item: MediaItem) -> Bool {
        activeTrackPath == item.relativePath
    }

    func hasCompletedFirstListen(for item: MediaItem) -> Bool {
        resultsByPath[item.relativePath]?.completedFullListen == true
    }

    func result(for item: MediaItem) -> WholeSongAIResult? {
        resultsByPath[item.relativePath]
    }

    /// True when the track appears unknown/unidentified and has not yet completed its first-time full-song AI listen.
    func isUnknownSongNeedingFirstListen(_ item: MediaItem) -> Bool {
        guard !item.relativePath.hasPrefix("__remote__/"),
              !hasCompletedFirstListen(for: item),
              !MediaManager.shared.isArtistVerified(for: item) else {
            return false
        }

        if let dur = item.durationSeconds, dur > 1800 {
            return false
        }

        let rawArtist = item.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ignoredChannels = ListeningWrappedService.shared.ignoredChannels
        let extracted = ArtistDatabase.extractArtists(
            rawArtistTag: rawArtist.isEmpty ? nil : rawArtist,
            rawTitle: item.displayTitle,
            fileName: item.fileName,
            ignoredChannels: ignoredChannels,
            isArtistVerified: false
        )

        let normArtist = ArtistDatabase.normalizeLookupKey(extracted.primaryArtist)
        if normArtist.isEmpty || normArtist == "unknown artist" {
            return true
        }
        if ArtistDatabase.looksLikeUploaderChannel(extracted.primaryArtist, customIgnoredChannels: ignoredChannels) {
            return true
        }

        let hasAlbum = !(item.album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if !extracted.matchedFromCatalog && !hasAlbum {
            return true
        }

        return false
    }

    /// While an unknown song is on its first listen (before AI finishes listening to the whole song),
    /// lyrics should not be guessed prematurely so the UI cleanly displays "No lyrics for first time listen".
    func shouldDeferOnlineLyricsForFirstListen(_ item: MediaItem) -> Bool {
        guard !item.relativePath.hasPrefix("__remote__/") else { return false }
        return isUnknownSongNeedingFirstListen(item) || isListening(to: item)
    }

    func handlePlaybackStarted(for item: MediaItem) {
        guard !item.relativePath.hasPrefix("__remote__/") else {
            if activeTrackPath != nil {
                cancelActiveListen()
            }
            return
        }

        if activeTrackPath == item.relativePath {
            return
        }

        if activeTrackPath != nil {
            cancelActiveListen()
        }

        if isUnknownSongNeedingFirstListen(item) {
            startWholeSongListen(for: item, force: false)
        }
    }

    func triggerIfFirstTimeUnknown(item: MediaItem) {
        guard !item.relativePath.hasPrefix("__remote__/"),
              !hasCompletedFirstListen(for: item),
              activeTrackPath != item.relativePath else {
            return
        }
        if let dur = item.durationSeconds, dur > 1800 {
            return
        }
        startWholeSongListen(for: item, force: false)
    }

    func startWholeSongListen(for item: MediaItem, force: Bool = true) {
        guard !item.relativePath.hasPrefix("__remote__/") else { return }
        if !force && (hasCompletedFirstListen(for: item) || activeTrackPath == item.relativePath) {
            return
        }

        activeTask?.cancel()
        activeTrackPath = item.relativePath
        progressFraction = 0.02
        statusMessage = "AI preparing to listen to whole song..."
        lastError = nil

        let capturedItem = item
        activeTask = Task { [weak self] in
            await self?.runFullSongAnalysis(for: capturedItem)
        }
    }

    func markCompletedFromImport(
        relativePath: String,
        title: String?,
        album: String?,
        artist: String?,
        genre: String?,
        heardWordCount: Int,
        heardExcerpt: String?,
        hasLyrics: Bool
    ) {
        if activeTrackPath == relativePath {
            cancelActiveListen()
        }
        resultsByPath[relativePath] = WholeSongAIResult(
            relativePath: relativePath,
            completedFullListen: true,
            identifiedTitle: title,
            identifiedAlbum: album,
            identifiedArtist: artist,
            identifiedGenre: genre,
            confidenceScore: hasLyrics ? 100 : (heardWordCount > 0 ? 75 : 50),
            heardWordCount: heardWordCount,
            heardExcerpt: heardExcerpt,
            generatedLyricsAvailable: hasLyrics,
            analyzedAt: .now
        )
        scheduleSave()
    }

    func cancelActiveListen() {
        activeTask?.cancel()
        activeTask = nil
        activeTrackPath = nil
        progressFraction = 0
        statusMessage = nil
    }

    func rekeyPath(from oldPath: String, to newPath: String) {
        if activeTrackPath == oldPath {
            activeTrackPath = newPath
        }
        if var existing = resultsByPath.removeValue(forKey: oldPath) {
            existing = WholeSongAIResult(
                relativePath: newPath,
                completedFullListen: existing.completedFullListen,
                identifiedTitle: existing.identifiedTitle,
                identifiedAlbum: existing.identifiedAlbum,
                identifiedArtist: existing.identifiedArtist,
                identifiedGenre: existing.identifiedGenre,
                confidenceScore: existing.confidenceScore,
                heardWordCount: existing.heardWordCount,
                heardExcerpt: existing.heardExcerpt,
                generatedLyricsAvailable: existing.generatedLyricsAvailable,
                analyzedAt: existing.analyzedAt
            )
            resultsByPath[newPath] = existing
            scheduleSave()
        }
    }

    func removePaths(matching predicate: (String) -> Bool) {
        var changed = false
        for key in Array(resultsByPath.keys) where predicate(key) {
            resultsByPath.removeValue(forKey: key)
            changed = true
        }
        if let active = activeTrackPath, predicate(active) {
            cancelActiveListen()
        }
        if changed {
            scheduleSave()
        }
    }

    // MARK: - Full-Song Listening & Decision Pipeline

    private func runFullSongAnalysis(for item: MediaItem) async {
        defer {
            if activeTrackPath == item.relativePath {
                activeTrackPath = nil
            }
        }

        let authStatus = await Self.requestSpeechPermission()
        guard !Task.isCancelled else { return }
        guard authStatus == .authorized else {
            lastError = "Speech Recognition permission is required for AI listening."
            statusMessage = nil
            progressFraction = 0
            return
        }

        guard let recognizer = Self.makeRecognizer(), recognizer.isAvailable else {
            lastError = "Speech Recognition is currently unavailable on this device."
            statusMessage = nil
            progressFraction = 0
            return
        }

        let asset = AVURLAsset(url: item.fileURL)
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !audioTracks.isEmpty else {
            lastError = "No decodable audio track found for AI listening."
            statusMessage = nil
            progressFraction = 0
            return
        }

        let loadedDur = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) }
        let totalSec: Double
        if let loadedDur, loadedDur.isFinite, loadedDur > 1.0 {
            totalSec = loadedDur
        } else if let knownDur = item.durationSeconds, knownDur.isFinite, knownDur > 1.0 {
            totalSec = knownDur
        } else {
            totalSec = 0
        }

        guard totalSec > 1.0 else {
            lastError = "Song duration could not be read."
            statusMessage = nil
            progressFraction = 0
            return
        }

        // Listen across the whole song in clean 24s chunks so iOS speech limits never truncate it.
        let effectiveSpan = min(totalSec, 1800.0)
        let chunkSize = 24.0
        var windows: [(start: Double, duration: Double)] = []
        var cursor = 0.0
        while cursor < effectiveSpan {
            let remaining = effectiveSpan - cursor
            if remaining < 1.5 && !windows.isEmpty {
                let prev = windows.removeLast()
                windows.append((prev.start, prev.duration + remaining))
                break
            }
            let len = min(chunkSize, remaining)
            windows.append((cursor, len))
            cursor += chunkSize
        }

        var allWords: [TimedHeardWord] = []
        var transcriptChunks: [String] = []
        let sourceFileURL = item.fileURL

        for (idx, window) in windows.enumerated() {
            if Task.isCancelled { return }

            progressFraction = max(0.03, (Double(idx) / Double(max(1, windows.count))) * 0.82)
            statusMessage = "AI listening to whole song (\(idx + 1)/\(windows.count))..."

            let chunkResult = await Self.exportAndTranscribeChunk(
                sourceFileURL: sourceFileURL,
                startSeconds: window.start,
                durationSeconds: window.duration,
                recognizer: recognizer
            )
            if Task.isCancelled { return }

            if let chunkResult {
                allWords.append(contentsOf: chunkResult.words)
                let cleaned = chunkResult.formattedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    transcriptChunks.append(cleaned)
                }
            }
        }

        if Task.isCancelled { return }

        // Step 2: Create full-song lyrics after listening to the entire song
        progressFraction = 0.86
        statusMessage = "Creating lyrics from full song..."

        let fullTranscript = transcriptChunks.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let aiGeneratedLines = Self.buildSyncedLyricLines(from: allWords, totalDuration: totalSec)

        // Step 3: Decide what song, album, and artist it belongs to
        progressFraction = 0.92
        statusMessage = "Deciding song, album & artist..."

        let lyricClues = Self.extractRepresentativeClues(
            fromTranscript: fullTranscript,
            lines: aiGeneratedLines
        )

        let verification = await TrackVerificationService.identifyFromFullSongTranscript(
            fullTranscript: fullTranscript,
            lyricClues: lyricClues,
            localDuration: totalSec,
            rawTitle: item.displayTitle,
            rawArtist: item.artist,
            sourceVideoID: MediaManager.shared.sourceVideoID(for: item),
            ignoredChannels: ListeningWrappedService.shared.ignoredChannels
        )
        if Task.isCancelled { return }

        let topCandidate = verification.candidates.first
        let topHasLyricEvidence = topCandidate?.matchReasons.contains(where: { $0.contains("Lyrics") }) == true
        let topTitleMatches = topCandidate.map {
            ArtistDatabase.normalizeLookupKey($0.trackTitle) == ArtistDatabase.normalizeLookupKey(item.displayTitle)
        } ?? false
        let isConfidentMatch: Bool = {
            guard let top = topCandidate else { return false }
            if top.score >= 76 { return true }
            if topHasLyricEvidence && (top.score >= 66 || (topTitleMatches && top.score >= 56)) { return true }
            return false
        }()

        var decidedTitle = item.displayTitle
        var decidedArtist = item.artist
        var decidedAlbum = item.album
        var decidedGenre: String?
        var decidedArtworkURL: URL?
        var confidenceScore = topCandidate?.score ?? 0

        if isConfidentMatch, let top = topCandidate {
            decidedTitle = top.trackTitle
            decidedArtist = top.artistName
            decidedAlbum = top.albumName
            decidedGenre = top.genre ?? ArtistDatabase.genre(forArtist: top.artistName)
            decidedArtworkURL = top.artworkURL
        } else {
            confidenceScore = 0
        }

        // Download artwork if missing and matched
        var downloadedArtwork: UIImage?
        if MediaManager.shared.thumbnails[item.relativePath] == nil,
           let artURL = decidedArtworkURL {
            if let (imgData, _) = try? await URLSession.shared.data(from: artURL) {
                downloadedArtwork = UIImage(data: imgData)
            }
        }
        if Task.isCancelled { return }

        // Only overwrite track title/artist/album when verification reached high confidence.
        let cleanFinalArtist = decidedArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanFinalAlbum = decidedAlbum?.trimmingCharacters(in: .whitespacesAndNewlines)

        if isConfidentMatch {
            MediaManager.shared.updateTrackInfo(
                for: item,
                title: decidedTitle,
                artist: cleanFinalArtist,
                album: cleanFinalAlbum,
                coverImage: downloadedArtwork,
                markArtistVerified: true,
                genre: decidedGenre
            )
        }

        let refreshedItem = MediaManager.shared.items.first(where: { $0.relativePath == item.relativePath }) ?? item

        // Finalize Lyrics (official synced lyrics if matched & overlapping what AI heard, otherwise AI whole-song synced lyrics)
        let targetKey = SyncedLyricsService.shared.cacheKey(for: refreshedItem)
        var finalResolvedLyrics: ResolvedTrackLyrics?

        if isConfidentMatch {
            if let official = await SyncedLyricsService.shared.fetchOfficialLyricsCandidate(
                cacheKey: targetKey,
                song: decidedTitle,
                artist: cleanFinalArtist,
                duration: totalSec
            ) {
                let officialPlain = official.lines
                    .filter { !$0.isInstrumentalBreak }
                    .map(\.text)
                    .joined(separator: " ")
                let overlapsHeard = allWords.count < 8 ||
                    fullTranscript.isEmpty ||
                    TrackVerificationService.lyricsOverlapTranscript(officialPlain, transcript: fullTranscript)

                if official.isTimeSynced && overlapsHeard {
                    finalResolvedLyrics = official
                } else if !aiGeneratedLines.isEmpty {
                    finalResolvedLyrics = ResolvedTrackLyrics(
                        cacheKey: targetKey,
                        trackTitle: decidedTitle,
                        artistName: cleanFinalArtist,
                        isTimeSynced: true,
                        sourceLabel: "AI Whole-Song Lyrics",
                        attributionText: "Listened to full song • Identified by AI",
                        syncedOffsetSeconds: 0,
                        lines: aiGeneratedLines
                    )
                } else if overlapsHeard {
                    finalResolvedLyrics = official
                }
            }
        }

        if finalResolvedLyrics == nil && !aiGeneratedLines.isEmpty {
            finalResolvedLyrics = ResolvedTrackLyrics(
                cacheKey: targetKey,
                trackTitle: decidedTitle,
                artistName: cleanFinalArtist.isEmpty ? "Unknown Artist" : cleanFinalArtist,
                isTimeSynced: true,
                sourceLabel: "AI Whole-Song Lyrics",
                attributionText: isConfidentMatch
                    ? "Listened to full song • Identified by AI"
                    : "Generated by AI after listening to full song",
                syncedOffsetSeconds: 0,
                lines: aiGeneratedLines
            )
        }

        if let finalResolvedLyrics {
            SyncedLyricsService.shared.installLyrics(finalResolvedLyrics, for: refreshedItem)
        } else if MediaManager.shared.currentItem?.relativePath == refreshedItem.relativePath {
            SyncedLyricsService.shared.lastError = "No lyrics for first time listen"
        }

        let excerpt = fullTranscript.isEmpty
            ? nil
            : String(fullTranscript.split(separator: " ").prefix(16).joined(separator: " "))

        let record = WholeSongAIResult(
            relativePath: item.relativePath,
            completedFullListen: true,
            identifiedTitle: decidedTitle,
            identifiedAlbum: cleanFinalAlbum,
            identifiedArtist: cleanFinalArtist.isEmpty ? nil : cleanFinalArtist,
            identifiedGenre: decidedGenre,
            confidenceScore: confidenceScore,
            heardWordCount: allWords.count,
            heardExcerpt: excerpt,
            generatedLyricsAvailable: finalResolvedLyrics != nil,
            analyzedAt: .now
        )
        resultsByPath[item.relativePath] = record
        scheduleSave()

        progressFraction = 1.0
        if isConfidentMatch {
            let albumSuffix = (cleanFinalAlbum?.isEmpty == false) ? " • \(cleanFinalAlbum!)" : ""
            MediaManager.shared.statusMessage = "AI matched: \(decidedTitle) — \(cleanFinalArtist)\(albumSuffix)"
        } else if finalResolvedLyrics != nil {
            MediaManager.shared.statusMessage = "AI finished listening and created lyrics"
        }
        statusMessage = nil
    }

    // MARK: - Chunk Export & Speech Recognition

    nonisolated private static func requestSpeechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined {
            return current
        }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    nonisolated private static func makeRecognizer() -> SFSpeechRecognizer? {
        if let local = SFSpeechRecognizer(locale: Locale.current), local.isAvailable {
            return local
        }
        if let enUS = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), enUS.isAvailable {
            return enUS
        }
        return SFSpeechRecognizer()
    }

    nonisolated private static func exportAndTranscribeChunk(
        sourceFileURL: URL,
        startSeconds: Double,
        durationSeconds: Double,
        recognizer: SFSpeechRecognizer
    ) async -> ChunkTranscription? {
        let tempChunkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai_whole_song_\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tempChunkURL) }

        let asset = AVURLAsset(url: sourceFileURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return nil
        }
        exportSession.outputURL = tempChunkURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, startSeconds), preferredTimescale: 600),
            duration: CMTime(seconds: max(0.5, durationSeconds), preferredTimescale: 600)
        )

        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                exportSession.exportAsynchronously {
                    cont.resume()
                }
            }
        } onCancel: {
            exportSession.cancelExport()
        }

        guard !Task.isCancelled,
              exportSession.status == .completed,
              FileManager.default.fileExists(atPath: tempChunkURL.path) else {
            return nil
        }

        return await transcribeChunk(
            at: tempChunkURL,
            recognizer: recognizer,
            chunkStartOffset: startSeconds,
            chunkDuration: durationSeconds
        )
    }

    nonisolated private static func transcribeChunk(
        at url: URL,
        recognizer: SFSpeechRecognizer,
        chunkStartOffset: Double,
        chunkDuration: Double
    ) async -> ChunkTranscription? {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }

        let box = TranscriptionBox()
        let timeoutSec = max(20.0, chunkDuration + 10.0)

        return await withCheckedContinuation { (cont: CheckedContinuation<ChunkTranscription?, Never>) in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    let words: [TimedHeardWord] = result.bestTranscription.segments.compactMap { seg in
                        let token = seg.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !token.isEmpty else { return nil }
                        let absStart = max(0, chunkStartOffset + seg.timestamp)
                        let absEnd = max(absStart + 0.08, absStart + seg.duration)
                        return TimedHeardWord(text: token, startTime: absStart, endTime: absEnd)
                    }
                    box.update(ChunkTranscription(words: words, formattedText: result.bestTranscription.formattedString))
                }
                if result?.isFinal == true || error != nil {
                    if let done = box.finishOnce() {
                        cont.resume(returning: done)
                    }
                }
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSec) {
                task.finish()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
                    if let done = box.finishOnce() {
                        task.cancel()
                        cont.resume(returning: done)
                    }
                }
            }
        }
    }

    // MARK: - Whole-Song Lyric Assembly & Clue Extraction

    nonisolated private static func buildSyncedLyricLines(
        from rawWords: [TimedHeardWord],
        totalDuration: Double
    ) -> [SyncedLyricLine] {
        let sortedWords = rawWords
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.startTime < $1.startTime }

        guard !sortedWords.isEmpty else { return [] }

        var lineGroups: [[TimedHeardWord]] = []
        var currentGroup: [TimedHeardWord] = []

        for word in sortedWords {
            if let prev = currentGroup.last {
                let gap = word.startTime - prev.endTime
                let prevEndsSentence = prev.text.hasSuffix(".") || prev.text.hasSuffix("!") || prev.text.hasSuffix("?")
                let prevEndsClause = prev.text.hasSuffix(",") || prev.text.hasSuffix(";")
                let shouldBreak = gap >= 0.72
                    || prevEndsSentence
                    || (prevEndsClause && currentGroup.count >= 4)
                    || currentGroup.count >= 9

                if shouldBreak {
                    lineGroups.append(currentGroup)
                    currentGroup = [word]
                } else {
                    currentGroup.append(word)
                }
            } else {
                currentGroup.append(word)
            }
        }
        if !currentGroup.isEmpty {
            lineGroups.append(currentGroup)
        }

        var lines: [SyncedLyricLine] = []
        if let firstWord = lineGroups.first?.first, firstWord.startTime > 5.5 {
            lines.append(
                SyncedLyricLine(
                    startTime: 0.4,
                    endTime: max(1.0, firstWord.startTime - 0.35),
                    text: "",
                    words: [],
                    isInstrumentalBreak: true
                )
            )
        }

        for (idx, group) in lineGroups.enumerated() {
            guard let first = group.first, let last = group.last else { continue }
            let nextGroupStart: Double = {
                if idx + 1 < lineGroups.count, let nextFirst = lineGroups[idx + 1].first {
                    return nextFirst.startTime
                }
                return min(totalDuration, last.endTime + 2.5)
            }()

            let lineText = group.map(\.text).joined(separator: " ")
            let lineEnd = min(max(last.endTime, first.startTime + 0.5), max(last.endTime, nextGroupStart - 0.1))
            let wordTimings = group.map { w in
                LyricWordTiming(text: w.text, startTime: w.startTime, endTime: max(w.startTime + 0.06, w.endTime))
            }

            lines.append(
                SyncedLyricLine(
                    startTime: first.startTime,
                    endTime: lineEnd,
                    text: lineText,
                    words: wordTimings,
                    isInstrumentalBreak: false
                )
            )

            let gapToNext = nextGroupStart - lineEnd
            if idx + 1 < lineGroups.count && gapToNext >= 7.0 {
                lines.append(
                    SyncedLyricLine(
                        startTime: lineEnd + 0.35,
                        endTime: max(lineEnd + 1.0, nextGroupStart - 0.35),
                        text: "",
                        words: [],
                        isInstrumentalBreak: true
                    )
                )
            }
        }

        return lines
    }

    nonisolated private static func extractRepresentativeClues(
        fromTranscript transcript: String,
        lines: [SyncedLyricLine]
    ) -> [String] {
        var clues: [String] = []
        var seen = Set<String>()

        func appendClue(_ candidate: String) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard words.count >= 4 else { return }
            let clipped = words.prefix(12).map(String.init).joined(separator: " ")
            let key = clipped.lowercased()
            if seen.insert(key).inserted {
                clues.append(clipped)
            }
        }

        // 1. Most repeated 4-word phrase across the whole song (almost always the chorus hook)
        let normTokens = transcript
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9'\\s]", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        if normTokens.count >= 8 {
            var ngramCounts: [String: Int] = [:]
            for i in 0...(normTokens.count - 4) {
                let gram = normTokens[i..<(i + 4)].joined(separator: " ")
                ngramCounts[gram, default: 0] += 1
            }
            if let topHook = ngramCounts.max(by: { $0.value < $1.value }), topHook.value >= 2 {
                appendClue(topHook.key)
            }
        }

        // 2. Evenly spaced vocal lines from verse, chorus, and bridge/outro
        let vocalLines = lines.filter { !$0.isInstrumentalBreak && $0.text.split(separator: " ").count >= 4 }
        if !vocalLines.isEmpty {
            let indices = [
                vocalLines.count / 5,
                vocalLines.count / 2,
                (vocalLines.count * 4) / 5
            ]
            for idx in indices where vocalLines.indices.contains(idx) {
                appendClue(vocalLines[idx].text)
            }
        }

        if clues.isEmpty && !transcript.isEmpty {
            appendClue(transcript)
        }

        return Array(clues.prefix(4))
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: Self.stateFileURL),
              let decoded = try? JSONDecoder().decode([String: WholeSongAIResult].self, from: data) else {
            return
        }
        resultsByPath = decoded
    }

    private func scheduleSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            let snapshot = self.resultsByPath
            let url = Self.stateFileURL
            Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(snapshot) {
                    try? data.write(to: url, options: [.atomic])
                }
            }
        }
    }

    private final class TranscriptionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var latest: ChunkTranscription?

        func update(_ value: ChunkTranscription) {
            lock.lock()
            if !value.formattedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                latest = value
            }
            lock.unlock()
        }

        func finishOnce() -> ChunkTranscription? {
            lock.lock()
            defer { lock.unlock() }
            if finished { return nil }
            finished = true
            return latest
        }
    }
}
