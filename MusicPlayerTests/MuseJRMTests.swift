import AVFoundation
import XCTest
@testable import MusicPlayer

final class MuseJRMTests: XCTestCase {

    // MARK: - Multilingual & Punctuated Title Parsing

    func testParseTrackHintsJapaneseKoreanSpanishEnglish() {
        let yoasobi = ArtistDatabase.parseTrackHints(
            rawTitle: "YOASOBI「アイドル」 Official Music Video",
            rawArtistTag: "Ayase / YOASOBI"
        )
        XCTAssertEqual(yoasobi.songTitle, "アイドル")
        XCTAssertEqual(yoasobi.artistHint, "YOASOBI")

        let ado = ArtistDatabase.parseTrackHints(
            rawTitle: "【Ado】うっせぇわ",
            rawArtistTag: "Ado"
        )
        XCTAssertEqual(ado.songTitle, "うっせぇわ")
        XCTAssertEqual(ado.artistHint, "Ado")

        let newJeans = ArtistDatabase.parseTrackHints(
            rawTitle: "NewJeans (뉴진스) 'Super Shy' Official MV",
            rawArtistTag: "HYBE LABELS"
        )
        XCTAssertEqual(newJeans.songTitle, "Super Shy")
        XCTAssertEqual(newJeans.artistHint, "NewJeans")

        let badBunny = ArtistDatabase.parseTrackHints(
            rawTitle: "Bad Bunny - Tití Me Preguntó (Video Oficial) | Un Verano Sin Ti",
            rawArtistTag: "Bad Bunny"
        )
        XCTAssertEqual(badBunny.songTitle, "Tití Me Preguntó")
        XCTAssertEqual(badBunny.artistHint, "Bad Bunny")
        XCTAssertEqual(badBunny.albumHint, "Un Verano Sin Ti")

        let nujabes = ArtistDatabase.parseTrackHints(
            rawTitle: "Nujabes - Luv(sic) feat.Shing02 [Official Audio]",
            rawArtistTag: "Nujabes"
        )
        XCTAssertEqual(nujabes.songTitle, "Luv(sic)")
        XCTAssertEqual(nujabes.artistHint, "Nujabes")
    }

    // MARK: - Artist Compatibility & Derivative Act Guards

    func testArtistCompatibilityAndDerivativeRejection() {
        XCTAssertTrue(SyncedLyricsService.areArtistsCompatible(target: "Coda - Topic", candidate: "Coda"))
        XCTAssertFalse(SyncedLyricsService.areArtistsCompatible(target: "Coda", candidate: "Coda Piano Trio"))
        XCTAssertFalse(SyncedLyricsService.areArtistsCompatible(target: "Ado", candidate: "Ado (Lullaby Version)"))
        XCTAssertFalse(SyncedLyricsService.areArtistsCompatible(target: "Datfootdive", candidate: "Justin Bieber"))
        XCTAssertTrue(SyncedLyricsService.areArtistsCompatible(target: "BTS (방탄소년단)", candidate: "방탄소년단(BTS)"))
        XCTAssertTrue(SyncedLyricsService.areArtistsCompatible(target: "KAROL G, Shakira", candidate: "KAROL G"))
        XCTAssertTrue(SyncedLyricsService.areArtistsCompatible(target: "Nujabes", candidate: "Nujabes feat. Shing02"))
    }

    // MARK: - LRC Bilingual Deduplication & SongIdentificationService Helpers

    func testBilingualLRCDeduplicationAndTitlePreservation() {
        let lrc = """
        [00:10.00] 唯一無二じゃなくちゃイヤイヤ
        [00:10.00] Yuiitsumu ni janakucha iya iya
        [00:13.50] それこそ本物のアイ
        [00:13.50] Sorekoso honmono no ai
        """
        let parsed = SyncedLyricsService.parseLRCOrPlain(text: lrc, duration: 25.0)
        XCTAssertTrue(parsed.isSynced)
        let lyricLines = parsed.lines.filter { !$0.isInstrumentalBreak }
        XCTAssertEqual(lyricLines.count, 2)
        XCTAssertEqual(lyricLines[0].text, "唯一無二じゃなくちゃイヤイヤ")
        XCTAssertEqual(lyricLines[0].endTime, 13.50, accuracy: 0.05)
        XCTAssertEqual(lyricLines[1].text, "それこそ本物のアイ")

        XCTAssertEqual(SongIdentificationService.stripVersionNoise("Luv(sic)", keepVersionTags: false), "Luv(sic)")
        XCTAssertEqual(SongIdentificationService.similarity("BLOODY STREAM", "Bloody Stream"), 1.0, accuracy: 0.001)
    }

    // MARK: - Real Swift Audio Vocal-Curve Alignment (AVAssetReader + vDSP)

    func testAudioAlignmentRecoversLateLRCOnSynthesizedVocalFixture() async throws {
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("musejrm_sync_fixture_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        // Generate 22s stereo 44.1 kHz audio: quiet backing rumble + strong harmonic center-panned vocal bursts at 4..7.5s and 12..15.5s.
        let sr = 44100.0
        let totalDur = 22.0
        let frameCount = AVAudioFrameCount(sr * totalDur)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            XCTFail("Failed to allocate PCM buffer")
            return
        }
        buffer.frameLength = frameCount
        let chL = buffer.floatChannelData![0]
        let chR = buffer.floatChannelData![1]

        for i in 0..<Int(frameCount) {
            let t = Double(i) / sr
            let base = Float(0.08 * sin(2.0 * .pi * 95.0 * t))
            let inVocal1 = (t >= 4.0 && t <= 7.5)
            let inVocal2 = (t >= 12.0 && t <= 15.5)
            var vocal: Float = 0
            if inVocal1 || inVocal2 {
                vocal = Float(
                    0.30 * sin(2.0 * .pi * 380.0 * t)
                    + 0.24 * sin(2.0 * .pi * 760.0 * t)
                    + 0.18 * sin(2.0 * .pi * 1140.0 * t)
                    + 0.14 * sin(2.0 * .pi * 1520.0 * t)
                    + 0.10 * sin(2.0 * .pi * 2280.0 * t)
                )
            }
            chL[i] = base + vocal
            chR[i] = base + vocal
        }
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        do {
            let audioFile = try AVAudioFile(forWriting: wavURL, settings: pcmSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try audioFile.write(from: buffer)
        }

        let curve = await SongAudioListener.extractVocalCurve(for: wavURL)
        XCTAssertNotNil(curve)

        // Feed intentionally +1.3s late LRC lines (`5.3s` and `13.3s`) and verify autoAlign pulls them onto `4.0s` / `12.0s`.
        let lateLyrics = ResolvedTrackLyrics(
            cacheKey: "test-fixture",
            trackTitle: "Fixture Song",
            artistName: "Fixture Artist",
            isTimeSynced: true,
            sourceLabel: "Synced Lyrics",
            attributionText: "Test Fixture",
            syncedOffsetSeconds: 0,
            expectedDurationSeconds: totalDur,
            lines: [
                SyncedLyricLine(startTime: 5.3, endTime: 8.8, text: "First vocal phrase here", words: [], isInstrumentalBreak: false),
                SyncedLyricLine(startTime: 13.3, endTime: 16.8, text: "Second vocal phrase here", words: [], isInstrumentalBreak: false)
            ]
        )

        let aligned = await SongAudioListener.autoAlign(lyrics: lateLyrics, heard: nil, fileURL: wavURL, precomputedCurve: curve)
        let firstNonBreak = aligned.lines.first { !$0.isInstrumentalBreak }
        XCTAssertNotNil(firstNonBreak)
        if let first = firstNonBreak {
            XCTAssertLessThan(abs(first.startTime - 4.0), 0.45, "Expected aligned start near 4.0s, got \(first.startTime)")
        }
    }

    // MARK: - Duration-Matched LRC Keeps Original Timing (Coda "Crazy my Beat" regression)

    func testDurationMatchedLRCDetection() {
        let lrclib = Self.makeSyncedLyrics(
            starts: [31.65, 35.40, 39.15, 46.29, 53.27, 58.38],
            expectedDuration: 270.0,
            sourceLabel: "Synced Lyrics",
            attribution: "Time-synced via LRCLIB"
        )
        // Same master as the 269.6s file: trusted.
        XCTAssertTrue(SongAudioListener.isDurationMatchedSyncedLyrics(lrclib, audioDuration: 269.6))
        // Music video with a 20s skit: must still be free to section-align.
        XCTAssertFalse(SongAudioListener.isDurationMatchedSyncedLyrics(lrclib, audioDuration: 290.0))
        // Lyrics we already warped are never treated as trusted originals.
        let warped = Self.makeSyncedLyrics(
            starts: [32.80, 35.55, 39.95, 46.71, 53.67, 59.48],
            expectedDuration: 269.6,
            sourceLabel: "Synced Lyrics · auto-aligned",
            attribution: "Time-synced via LRCLIB · section-DTW (-4.0s..+5.0s)"
        )
        XCTAssertFalse(SongAudioListener.isDurationMatchedSyncedLyrics(warped, audioDuration: 269.6))
        XCTAssertFalse(SongAudioListener.isDurationMatchedSyncedLyrics(lrclib, audioDuration: nil))
    }

    func testDurationMatchedLRCIsNotRewarpedOnSynthesizedFixture() async throws {
        let bursts: [(Double, Double)] = [(4.0, 7.5), (12.0, 15.5), (22.0, 25.5), (30.0, 33.5)]
        let wavURL = try Self.writeVocalFixture(duration: 40.0, vocalBursts: bursts)
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let curve = await SongAudioListener.extractVocalCurve(for: wavURL)
        XCTAssertNotNil(curve)

        let original = Self.makeSyncedLyrics(
            starts: bursts.map { $0.0 },
            lineLength: 3.4,
            expectedDuration: 40.2,
            sourceLabel: "Synced Lyrics",
            attribution: "Time-synced via LRCLIB"
        )
        let aligned = await SongAudioListener.autoAlign(lyrics: original, heard: nil, fileURL: wavURL, precomputedCurve: curve)
        XCTAssertFalse((aligned.attributionText ?? "").contains("section-DTW"), "Duration-matched lyrics must not be section-warped")
        XCTAssertTrue((aligned.attributionText ?? "").contains(SongAudioListener.durationLockedNote))
        for (orig, got) in zip(original.lines, aligned.lines.filter { !$0.isInstrumentalBreak && !$0.isSpokenDialogue }) {
            XCTAssertEqual(got.text, orig.text)
            XCTAssertLessThan(abs(got.startTime - orig.startTime), 0.5, "\(orig.text) moved from \(orig.startTime) to \(got.startTime)")
        }

        // Different cut (expected 60s vs 40s audio) keeps the normal re-alignment path.
        let otherCut = Self.makeSyncedLyrics(
            starts: bursts.map { $0.0 },
            lineLength: 3.4,
            expectedDuration: 60.0,
            sourceLabel: "Synced Lyrics",
            attribution: "Time-synced via LRCLIB"
        )
        let otherAligned = await SongAudioListener.autoAlign(lyrics: otherCut, heard: nil, fileURL: wavURL, precomputedCurve: curve)
        XCTAssertFalse((otherAligned.attributionText ?? "").contains(SongAudioListener.durationLockedNote))
    }

    // MARK: - Vocal Adlib Tracks Must Not Be Cached As Dots (datfootdive "stay" regression)

    func testDotsOnlyCacheIsRebuiltForVocalTracks() {
        let dots = ResolvedTrackLyrics(
            cacheKey: "stay",
            trackTitle: "stay",
            artistName: "Datfootdive",
            isTimeSynced: true,
            sourceLabel: "Instrumental",
            attributionText: "Instrumental / beat timeline",
            syncedOffsetSeconds: 0,
            expectedDurationSeconds: 180,
            lines: [
                SyncedLyricLine(startTime: 0.5, endTime: 16.1, text: "", words: [], isInstrumentalBreak: true),
                SyncedLyricLine(startTime: 16.5, endTime: 32.1, text: "", words: [], isInstrumentalBreak: true)
            ]
        )
        XCTAssertTrue(SyncedLyricsService.isDotsOnlyLyrics(dots))
        XCTAssertTrue(SyncedLyricsService.cachedLyricsNeedFreshCandidates(dots, title: "stay"))
        XCTAssertFalse(SyncedLyricsService.cachedLyricsNeedFreshCandidates(dots, title: "stay (Instrumental)"))

        let warped = Self.makeSyncedLyrics(
            starts: [32.80, 35.55, 39.95, 46.71],
            expectedDuration: 269.6,
            sourceLabel: "Synced Lyrics · auto-aligned",
            attribution: "Time-synced via LRCLIB · section-DTW (-4.0s..+5.0s)"
        )
        XCTAssertTrue(SyncedLyricsService.cachedLyricsNeedFreshCandidates(warped, title: "Crazy my Beat"))
        XCTAssertFalse(SyncedLyricsService.isDotsOnlyLyrics(warped))
    }

    func testSparseAdlibsBecomeSyncedTextLinesNotDots() {
        let heard = [
            HeardWord(token: "yeah", time: 12.0, endTime: 12.4),
            HeardWord(token: "stay", time: 12.5, endTime: 13.0),
            HeardWord(token: "with", time: 13.1, endTime: 13.3),
            HeardWord(token: "me", time: 13.35, endTime: 13.8),
            HeardWord(token: "stay", time: 41.0, endTime: 41.6)
        ]
        let built = SongAudioListener.buildSyncedLyricsFromHeard(
            heard,
            trackTitle: "stay",
            artistName: "Datfootdive",
            cacheKey: "stay",
            duration: 120
        )
        XCTAssertNotNil(built)
        guard let built else { return }
        XCTAssertEqual(built.sourceLabel, "Vocal Adlibs & Instrumental")
        XCTAssertFalse(SyncedLyricsService.isDotsOnlyLyrics(built))
        let textLines = built.lines.filter { !$0.isInstrumentalBreak }
        XCTAssertEqual(textLines.first?.text, "yeah stay with me")
        XCTAssertEqual(textLines.first?.startTime ?? -1, 12.0, accuracy: 0.01)
        XCTAssertTrue(built.lines.contains { $0.isInstrumentalBreak }, "Long gaps between adlibs keep instrumental dots")
    }

    func testVocalCurveDetectionAndStayRejectionReasons() async throws {
        XCTAssertFalse(SongAudioListener.curveIndicatesVocals(nil))
        let wavURL = try Self.writeVocalFixture(duration: 24.0, vocalBursts: [(2.0, 10.0), (13.0, 22.0)])
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let curve = await SongAudioListener.extractVocalCurve(for: wavURL)
        XCTAssertTrue(SongAudioListener.curveIndicatesVocals(curve), "Mostly-vocal fixture must not be treated as instrumental")

        // The four LRCLIB hits for datfootdive "stay" were all other songs; diagnostics must say why.
        let wrong = [
            Self.makeSyncedLyrics(starts: [1, 2, 3, 4], expectedDuration: 273, sourceLabel: "Synced Lyrics", attribution: nil, title: "Stay", artist: "Stay Design - Topic"),
            Self.makeSyncedLyrics(starts: [1, 2, 3, 4], expectedDuration: 239, sourceLabel: "Synced Lyrics", attribution: nil, title: "Stay - Rihanna", artist: "Stay - Rihanna"),
            Self.makeSyncedLyrics(starts: [1, 2, 3, 4], expectedDuration: 136, sourceLabel: "Synced Lyrics", attribution: nil, title: "Stay Homa", artist: "Stay Homas")
        ]
        let reasons = SyncedLyricsService.rejectionReasons(for: wrong, targetArtist: "datfootdive - Topic")
        XCTAssertEqual(reasons.count, 3)
        XCTAssertTrue(reasons.allSatisfy { $0.contains("artist mismatch") }, "\(reasons)")
    }

    // MARK: - Browser Page-Title File Names ("crazy my beat - Google Search")

    func testBrowserPageTitleSuffixIsNotParsedAsArtist() {
        XCTAssertEqual(ArtistDatabase.stripBrowserPageTitleSuffix("crazy my beat - Google Search"), "crazy my beat")
        XCTAssertEqual(ArtistDatabase.stripBrowserPageTitleSuffix("Luv(sic) - Google Search - Google Chrome"), "Luv(sic)")
        XCTAssertEqual(ArtistDatabase.stripBrowserPageTitleSuffix("Song - Artist - YouTube"), "Song - Artist")
        // Real song titles that happen to be browser-ish words stay untouched.
        XCTAssertEqual(ArtistDatabase.stripBrowserPageTitleSuffix("Sara Bareilles - Brave"), "Sara Bareilles - Brave")
        XCTAssertEqual(ArtistDatabase.stripBrowserPageTitleSuffix("stay"), "stay")

        let parsed = ArtistDatabase.parseTrackHints(
            rawTitle: "crazy my beat - Google Search",
            rawArtistTag: nil,
            fileName: "crazy my beat - Google Search.mp4"
        )
        XCTAssertEqual(parsed.songTitle.lowercased(), "crazy my beat")
        XCTAssertNotEqual(parsed.artistHint?.lowercased(), "google search")
        XCTAssertFalse(parsed.allArtists.contains { $0.lowercased().contains("google") })
    }

    // MARK: - Fixture Helpers

    private static func makeSyncedLyrics(
        starts: [Double],
        lineLength: Double = 2.5,
        expectedDuration: Double?,
        sourceLabel: String,
        attribution: String?,
        title: String = "Fixture Song",
        artist: String = "Fixture Artist"
    ) -> ResolvedTrackLyrics {
        let lines = starts.enumerated().map { idx, start in
            SyncedLyricLine(
                startTime: start,
                endTime: start + lineLength,
                text: "Fixture vocal phrase number \(idx + 1)",
                words: [],
                isInstrumentalBreak: false
            )
        }
        return ResolvedTrackLyrics(
            cacheKey: "fixture-\(title)-\(artist)",
            trackTitle: title,
            artistName: artist,
            isTimeSynced: true,
            sourceLabel: sourceLabel,
            attributionText: attribution,
            syncedOffsetSeconds: 0,
            expectedDurationSeconds: expectedDuration,
            lines: lines
        )
    }

    /// Writes a stereo 44.1 kHz WAV: quiet 95 Hz backing rumble + strong harmonic center-panned "vocal" bursts.
    private static func writeVocalFixture(duration: Double, vocalBursts: [(Double, Double)]) throws -> URL {
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("musejrm_fixture_\(UUID().uuidString).wav")
        let sr = 44100.0
        let frameCount = AVAudioFrameCount(sr * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "MuseJRMTests", code: 1)
        }
        buffer.frameLength = frameCount
        let chL = buffer.floatChannelData![0]
        let chR = buffer.floatChannelData![1]
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sr
            let base = Float(0.08 * sin(2.0 * .pi * 95.0 * t))
            var vocal: Float = 0
            if vocalBursts.contains(where: { t >= $0.0 && t <= $0.1 }) {
                vocal = Float(
                    0.30 * sin(2.0 * .pi * 380.0 * t)
                    + 0.24 * sin(2.0 * .pi * 760.0 * t)
                    + 0.18 * sin(2.0 * .pi * 1140.0 * t)
                    + 0.14 * sin(2.0 * .pi * 1520.0 * t)
                    + 0.10 * sin(2.0 * .pi * 2280.0 * t)
                )
            }
            chL[i] = base + vocal
            chR[i] = base + vocal
        }
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let audioFile = try AVAudioFile(forWriting: wavURL, settings: pcmSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try audioFile.write(from: buffer)
        return wavURL
    }

    // MARK: - SyncDiagnosticsService Ring Buffer & JSON Export

    func testSyncDiagnosticsServiceUpdateAndExport() throws {
        let testPath = "__xctest__/sample_track.mp4"
        SyncDiagnosticsService.shared.updateTrack(relativePath: testPath, fileName: "sample_track.mp4") { diag in
            diag.finalTitle = "BLOODY STREAM"
            diag.finalArtist = "Coda"
            diag.finalAlbum = "BLOODY STREAM - Single"
            diag.selectedLyricsSource = "Synced Lyrics"
            diag.alignmentVersion = SyncedLyricsService.currentAlignmentVersion
            diag.heardWordCount = 0
            diag.lyricsFallback = "Instrumental"
            diag.transcriptionRescue = "full-model listen heard 0 words"
        }
        let exportedURL = SyncDiagnosticsService.shared.exportDiagnosticsFileURL()
        XCTAssertNotNil(exportedURL)
        if let exportedURL {
            let data = try Data(contentsOf: exportedURL)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let tracks = obj?["tracks"] as? [[String: Any]]
            let entry = tracks?.first(where: { ($0["relativePath"] as? String) == testPath })
            XCTAssertNotNil(entry)
            XCTAssertEqual(entry?["lyricsFallback"] as? String, "Instrumental")
            XCTAssertEqual(entry?["heardWordCount"] as? Int, 0)
            XCTAssertEqual(obj?["alignmentVersion"] as? Int, 11)
            try? FileManager.default.removeItem(at: exportedURL)
        }
    }
}
