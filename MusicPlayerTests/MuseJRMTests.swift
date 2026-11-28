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
        XCTAssertEqual(parsed.lines.count, 2)
        XCTAssertEqual(parsed.lines[0].text, "唯一無二じゃなくちゃイヤイヤ")
        XCTAssertEqual(parsed.lines[0].endTime, 13.50, accuracy: 0.05)
        XCTAssertEqual(parsed.lines[1].text, "それこそ本物のアイ")

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
            let base = Float(0.02 * sin(2.0 * .pi * 95.0 * t))
            let inVocal1 = (t >= 4.0 && t <= 7.5)
            let inVocal2 = (t >= 12.0 && t <= 15.5)
            var vocal: Float = 0
            if inVocal1 || inVocal2 {
                vocal = Float(
                    0.35 * sin(2.0 * .pi * 380.0 * t)
                    + 0.22 * sin(2.0 * .pi * 760.0 * t)
                    + 0.14 * sin(2.0 * .pi * 1140.0 * t)
                )
            }
            chL[i] = base + vocal
            chR[i] = -base + vocal
        }
        let audioFile = try AVAudioFile(forWriting: wavURL, settings: format.settings)
        try audioFile.write(from: buffer)

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

        let aligned = await SongAudioListener.autoAlign(lyrics: lateLyrics, heard: nil, fileURL: wavURL)
        let firstNonBreak = aligned.lines.first { !$0.isInstrumentalBreak }
        XCTAssertNotNil(firstNonBreak)
        if let first = firstNonBreak {
            XCTAssertLessThan(abs(first.startTime - 4.0), 0.45, "Expected aligned start near 4.0s, got \(first.startTime)")
        }
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
        }
        let exportedURL = SyncDiagnosticsService.shared.exportDiagnosticsFileURL()
        XCTAssertNotNil(exportedURL)
        if let exportedURL {
            let data = try Data(contentsOf: exportedURL)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let tracks = obj?["tracks"] as? [[String: Any]]
            XCTAssertTrue(tracks?.contains(where: { ($0["relativePath"] as? String) == testPath }) ?? false)
            try? FileManager.default.removeItem(at: exportedURL)
        }
    }
}
