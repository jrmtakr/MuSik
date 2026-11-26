import AVFoundation
import Foundation
@preconcurrency import Speech

/// One word the on-device speech engine heard, with its time in the file.
struct HeardWord: Sendable, Hashable {
    let token: String
    let time: Double
}

/// What listening to the whole song concluded about a proposed song name.
enum ListeningVerdict: Sendable, Equatable {
    /// The sung words match that song's lyrics.
    case confirmed(matchRatio: Double)
    /// Plenty of clear vocals, but they don't match that song's lyrics: it's a different song.
    case contradicted(matchRatio: Double)
    /// Too few clear words (instrumental, heavy mix, other language): can't tell either way.
    case inconclusive
}

/// "Listens" to an entire imported song with Apple's on-device speech recognition, then
///   1. checks the words it heard against the lyrics of the song we think it is (confirm / reject the name), and
///   2. lines the synced lyrics up with THIS file — music videos have intros, skits and outros, so lyrics
///      timed for the album version drift. Every lyric line is re-timed against where it was actually heard,
///      piece by piece, so a skit in the middle of a video doesn't throw off the rest of the song.
/// Runs fully on the phone (no account, no key). Needs the Speech Recognition permission the app already asks for.
enum SongAudioListener {
    /// Seconds of audio per recognition request (Apple limits server requests to about a minute).
    private static let chunkSeconds: Double = 55

    // MARK: - Listening

    /// Transcribes the whole file. Returns nil when speech recognition isn't allowed or available.
    static func listen(to fileURL: URL, maxSeconds: Double = 15 * 60) async -> [HeardWord]? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else { return nil }

        let asset = AVURLAsset(url: fileURL)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 5,
              !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty else { return nil }

        let total = min(duration, maxSeconds)
        var heard: [HeardWord] = []
        var start: Double = 0
        while start < total {
            if Task.isCancelled { break }
            let length = min(chunkSeconds, total - start)
            if length < 2 { break }
            if let chunkURL = await exportAudioChunk(asset: asset, start: start, length: length) {
                let words = await recognize(url: chunkURL, recognizer: recognizer, offset: start)
                heard.append(contentsOf: words)
                try? FileManager.default.removeItem(at: chunkURL)
            }
            start += chunkSeconds
        }
        return heard
    }

    private static func exportAudioChunk(asset: AVAsset, start: Double, length: Double) async -> URL? {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("listen_\(UUID().uuidString).m4a")
        session.outputURL = out
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: length, preferredTimescale: 600)
        )
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        guard session.status == .completed, FileManager.default.fileExists(atPath: out.path) else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }

    private static func recognize(url: URL, recognizer: SFSpeechRecognizer, offset: Double) async -> [HeardWord] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        let gate = ResumeOnceGate()
        return await withCheckedContinuation { (cont: CheckedContinuation<[HeardWord], Never>) in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    let words = result.bestTranscription.segments.compactMap { seg -> HeardWord? in
                        let token = normalizeToken(seg.substring)
                        return token.isEmpty ? nil : HeardWord(token: token, time: offset + seg.timestamp)
                    }
                    if gate.claim() { cont.resume(returning: words) }
                } else if error != nil {
                    if gate.claim() { cont.resume(returning: []) }
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120) {
                task.cancel()
                if gate.claim() { cont.resume(returning: []) }
            }
        }
    }

    // MARK: - Confirming the song name

    /// Compares what was heard with the lyrics of the proposed song.
    static func verdict(heard: [HeardWord], lyrics: ResolvedTrackLyrics) -> ListeningVerdict {
        let meaningfulHeard = heard.filter { $0.token.count >= 3 && !stopWords.contains($0.token) }
        guard meaningfulHeard.count >= 25 else { return .inconclusive }

        var lyricVocabulary = Set<String>()
        for line in lyrics.lines {
            for token in tokens(line.text) where token.count >= 3 && !stopWords.contains(token) {
                lyricVocabulary.insert(token)
            }
        }
        guard lyricVocabulary.count >= 15 else { return .inconclusive }

        let matched = meaningfulHeard.filter { lyricVocabulary.contains($0.token) }.count
        let ratio = Double(matched) / Double(meaningfulHeard.count)
        let anchors = lyrics.isTimeSynced ? alignmentAnchors(heard: heard, lines: lyrics.lines).count : 0

        if ratio >= 0.3 || anchors >= 4 { return .confirmed(matchRatio: ratio) }
        if ratio < 0.1 && anchors == 0 && meaningfulHeard.count >= 60 { return .contradicted(matchRatio: ratio) }
        return .inconclusive
    }

    /// A distinctive run of heard words, for looking a song up by its lyrics when nothing else knows it.
    static func searchPhrases(from heard: [HeardWord], count: Int = 3) -> [String] {
        let words = heard.map(\.token)
        guard words.count >= 8 else { return [] }
        var phrases: [String] = []
        let step = max(8, words.count / (count + 1))
        var i = step / 2
        while i + 8 <= words.count && phrases.count < count {
            phrases.append(words[i..<(i + 8)].joined(separator: " "))
            i += step
        }
        return phrases
    }

    // MARK: - Lining lyrics up with this file

    private struct Anchor {
        let lyricTime: Double
        let fileTime: Double
    }

    /// Re-times every synced lyric line (and word) to where it was actually heard in this file.
    /// Returns nil when too little was heard to align safely.
    static func align(lyrics: ResolvedTrackLyrics, heard: [HeardWord]) -> ResolvedTrackLyrics? {
        guard lyrics.isTimeSynced, !lyrics.lines.isEmpty else { return nil }
        let anchors = alignmentAnchors(heard: heard, lines: lyrics.lines)
        guard !anchors.isEmpty else { return nil }

        func map(_ t: Double) -> Double {
            if anchors.count == 1 || t <= anchors[0].lyricTime {
                return t + (anchors[0].fileTime - anchors[0].lyricTime)
            }
            if let last = anchors.last, t >= last.lyricTime {
                return t + (last.fileTime - last.lyricTime)
            }
            for k in 0..<(anchors.count - 1) {
                let a = anchors[k], b = anchors[k + 1]
                guard t >= a.lyricTime && t <= b.lyricTime else { continue }
                let lyricGap = b.lyricTime - a.lyricTime
                let fileGap = b.fileTime - a.fileTime
                let slope = lyricGap > 0.01 ? fileGap / lyricGap : 1
                if slope > 0.9 && slope < 1.12 {
                    // Same tempo: interpolate smoothly.
                    return a.fileTime + (t - a.lyricTime) * slope
                }
                // A skit/break was inserted (or cut) between these two lines: keep each line glued
                // to the nearer anchor instead of stretching everything in between.
                let nearA = (t - a.lyricTime) <= (b.lyricTime - t)
                let ref = nearA ? a : b
                return t + (ref.fileTime - ref.lyricTime)
            }
            return t
        }

        var remapped: [SyncedLyricLine] = []
        for line in lyrics.lines {
            let newStart = max(0, map(line.startTime))
            let newEnd = max(newStart, map(line.endTime))
            let newWords = line.words.map {
                LyricWordTiming(id: $0.id, text: $0.text, startTime: max(0, map($0.startTime)), endTime: max(0, map($0.endTime)))
            }
            remapped.append(SyncedLyricLine(
                id: line.id,
                startTime: newStart,
                endTime: newEnd,
                text: line.text,
                words: newWords,
                isInstrumentalBreak: line.isInstrumentalBreak
            ))
        }
        // Keep lines in order even if two anchors disagreed slightly.
        for i in 1..<max(1, remapped.count) where remapped[i].startTime < remapped[i - 1].startTime {
            let fixed = remapped[i - 1].startTime + 0.05
            remapped[i] = SyncedLyricLine(
                id: remapped[i].id,
                startTime: fixed,
                endTime: max(fixed, remapped[i].endTime),
                text: remapped[i].text,
                words: remapped[i].words,
                isInstrumentalBreak: remapped[i].isInstrumentalBreak
            )
        }

        return ResolvedTrackLyrics(
            cacheKey: lyrics.cacheKey,
            trackTitle: lyrics.trackTitle,
            artistName: lyrics.artistName,
            isTimeSynced: true,
            sourceLabel: "Synced Lyrics · aligned to this file",
            attributionText: (lyrics.attributionText ?? "LRCLIB") + " · re-timed by listening (\(anchors.count) anchor lines)",
            syncedOffsetSeconds: 0,
            tempoScale: 1.0,
            expectedDurationSeconds: nil,
            lines: remapped
        )
    }

    /// Finds lyric lines that were clearly heard, and when. Keeps only anchors that move forward in
    /// both lyric time and file time (longest consistent chain), so a misheard word can't scramble timing.
    private static func alignmentAnchors(heard: [HeardWord], lines: [SyncedLyricLine]) -> [Anchor] {
        guard heard.count >= 6 else { return [] }
        var candidates: [Anchor] = []

        for line in lines where !line.isInstrumentalBreak {
            let lineTokens = tokens(line.text).filter { !$0.isEmpty }
            guard lineTokens.count >= 3 else { continue }
            let needed = Set(lineTokens)
            let window = lineTokens.count + 3
            var bestScore = 0.0
            var bestStart: Int?
            var i = 0
            while i < heard.count {
                let end = min(heard.count, i + window)
                var hits = Set<String>()
                var firstHit: Int?
                for j in i..<end where needed.contains(heard[j].token) {
                    if firstHit == nil { firstHit = j }
                    hits.insert(heard[j].token)
                }
                let score = Double(hits.count) / Double(needed.count)
                if score > bestScore, let firstHit {
                    bestScore = score
                    bestStart = firstHit
                }
                i += 1
            }
            if bestScore >= 0.6, let bestStart, Set(lineTokens).count >= 3 {
                candidates.append(Anchor(lyricTime: line.startTime, fileTime: max(0, heard[bestStart].time - 0.15)))
            }
        }
        guard !candidates.isEmpty else { return [] }

        // Longest chain increasing in both lyric time and file time.
        let sorted = candidates.sorted { $0.lyricTime < $1.lyricTime }
        var length = Array(repeating: 1, count: sorted.count)
        var previous = Array(repeating: -1, count: sorted.count)
        for i in 0..<sorted.count {
            for j in 0..<i where sorted[j].fileTime < sorted[i].fileTime && sorted[j].lyricTime < sorted[i].lyricTime {
                if length[j] + 1 > length[i] {
                    length[i] = length[j] + 1
                    previous[i] = j
                }
            }
        }
        guard var idx = length.indices.max(by: { length[$0] < length[$1] }) else { return [] }
        var chain: [Anchor] = []
        while idx >= 0 {
            chain.append(sorted[idx])
            idx = previous[idx]
        }
        return chain.reversed()
    }

    // MARK: - Text helpers

    static func normalizeToken(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map { Character($0) })
    }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "/" })
            .map { normalizeToken(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "you", "your", "for", "but", "not", "are", "was", "with", "that", "this", "its",
        "yeah", "ooh", "ohh", "oh", "na", "la", "hey", "uh", "huh", "baby", "got", "get", "all", "just",
        "can", "cant", "dont", "now", "one", "out", "what", "when", "who", "how", "she", "him", "her", "his"
    ]
}
