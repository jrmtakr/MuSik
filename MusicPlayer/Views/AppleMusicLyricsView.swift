import SwiftUI
import UIKit

// MARK: - Artwork Dominant Palette Extractor & Apple Music Living Backdrop

enum AppleMusicPaletteExtractor {
    static func colors(from image: UIImage?) -> [Color] {
        guard let cgImage = image?.cgImage else {
            return defaultPalette
        }
        let width = 4
        let height = 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return defaultPalette
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Sample distinct quadrants for vibrant living orbs
        let indices = [0, 3, 10, 15]
        var extracted: [Color] = []
        for idx in indices {
            let off = idx * 4
            let r = CGFloat(pixels[off]) / 255.0
            let g = CGFloat(pixels[off + 1]) / 255.0
            let b = CGFloat(pixels[off + 2]) / 255.0
            let uiColor = UIColor(red: r, green: g, blue: b, alpha: 1)

            var h: CGFloat = 0
            var s: CGFloat = 0
            var br: CGFloat = 0
            var a: CGFloat = 0
            if uiColor.getHue(&h, saturation: &s, brightness: &br, alpha: &a) {
                let boostedSat = min(0.92, max(0.32, s * 1.35))
                let balancedBr = min(0.68, max(0.22, br * 0.92))
                extracted.append(Color(hue: h, saturation: boostedSat, brightness: balancedBr))
            } else {
                extracted.append(Color(red: r * 0.65, green: g * 0.65, blue: b * 0.65))
            }
        }
        return extracted.count >= 3 ? extracted : defaultPalette
    }

    static let defaultPalette: [Color] = [
        Color(red: 0.45, green: 0.14, blue: 0.28),
        Color(red: 0.15, green: 0.22, blue: 0.50),
        Color(red: 0.30, green: 0.12, blue: 0.42),
        Color(red: 0.10, green: 0.32, blue: 0.38)
    ]
}

struct AppleMusicLivingBackground: View {
    let artwork: UIImage?
    var artworkKey: String = ""
    var isPlaying: Bool = true

    @State private var drift = false

    private var palette: [Color] {
        AppleMusicPaletteExtractor.colors(from: artwork)
    }

    var body: some View {
        let colors = palette
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.07)

            GeometryReader { geo in
                let w = max(geo.size.width, 320)
                let h = max(geo.size.height, 480)
                ZStack {
                    Circle()
                        .fill(colors[0].opacity(0.85))
                        .frame(width: w * 1.15, height: w * 1.15)
                        .blur(radius: 85)
                        .offset(
                            x: drift ? -w * 0.22 : w * 0.14,
                            y: drift ? -h * 0.28 : -h * 0.08
                        )

                    Circle()
                        .fill(colors[1].opacity(0.80))
                        .frame(width: w * 1.05, height: w * 1.05)
                        .blur(radius: 90)
                        .offset(
                            x: drift ? w * 0.28 : -w * 0.16,
                            y: drift ? h * 0.18 : h * 0.04
                        )

                    Circle()
                        .fill((colors.count > 2 ? colors[2] : colors[0]).opacity(0.75))
                        .frame(width: w * 0.95, height: w * 0.95)
                        .blur(radius: 80)
                        .offset(
                            x: drift ? -w * 0.12 : w * 0.22,
                            y: drift ? h * 0.34 : h * 0.22
                        )

                    if let artwork {
                        Image(uiImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: w, height: h)
                            .blur(radius: 65)
                            .opacity(0.28)
                            .clipped()
                    }
                }
                .frame(width: w, height: h)
            }

            LinearGradient(
                colors: [
                    Color.black.opacity(0.25),
                    Color.black.opacity(0.32),
                    Color.black.opacity(0.55)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 11.0).repeatForever(autoreverses: true)) {
                drift.toggle()
            }
        }
        .animation(.easeInOut(duration: 0.7), value: artworkKey)
    }
}

// MARK: - 1:1 Apple Music Time-Synced Lyrics View

struct AppleMusicLyricsView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(SyncedLyricsService.self) private var lyricsService
    @Environment(AppSettings.self) private var settings

    let item: MediaItem
    let onOpenGeniusWeb: (String, String) -> Void

    @State private var tiktokMedia = TikTokMediaService.shared
    @State private var wholeSongAI = WholeSongAIService.shared
    @State private var lastSyncWallTime: Date = .now
    @State private var lastSyncPlaybackTime: Double = 0
    @State private var isUserScrolling = false
    @State private var resumeAutoScrollTask: Task<Void, Never>?
    @State private var copiedBannerText: String?
    @State private var randomGifURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            aiStatusHeaderBar

            ZStack(alignment: .bottom) {
                if let lyrics = lyricsService.currentLyrics, !lyrics.lines.isEmpty {
                    TimelineView(.animation(minimumInterval: mediaManager.isPlaying ? (1.0 / 30.0) : 0.25)) { timeline in
                        let effectiveTime = interpolatedPlaybackTime(
                            at: timeline.date,
                            offset: lyrics.syncedOffsetSeconds,
                            tempoScale: lyrics.tempoScale
                        )
                        let activeIdx = lyrics.isTimeSynced ? activeLineIndex(in: lyrics.lines, at: effectiveTime) : nil

                        lyricsScrollContent(
                            lyrics: lyrics,
                            effectiveTime: effectiveTime,
                            activeIndex: activeIdx
                        )
                    }
                } else if lyricsService.currentLoadingKey != nil {
                    VStack(spacing: 14) {
                        ProgressView()
                            .tint(.white)
                            .controlSize(.large)
                        Text("Finding Synced Lyrics...")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(item.displayTitle)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyOrErrorLyricsView
                }

                VStack(spacing: 8) {
                    if let copiedBannerText {
                        Text(copiedBannerText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                            .transition(.opacity)
                    }

                    if isUserScrolling, lyricsService.currentLyrics?.isTimeSynced == true {
                        Button {
                            AppHaptics.selection()
                            isUserScrolling = false
                            resumeAutoScrollTask?.cancel()
                        } label: {
                            Label("Back to Current Line", systemImage: "arrow.up.and.down.text.horizontal")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.8))
                        }
                        .buttonStyle(.plain)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .onAppear {
            syncClockSnapshot()
            tiktokMedia.refreshIfDue()
            pickRandomTikTokGif()
            lyricsService.loadLyricsIfNeeded(for: item)
        }
        .onChange(of: item.relativePath) { _, _ in
            isUserScrolling = false
            syncClockSnapshot()
            pickRandomTikTokGif()
            lyricsService.loadLyricsIfNeeded(for: item)
        }
        .onChange(of: lyricsService.currentLoadingKey) { oldKey, newKey in
            if oldKey != nil, newKey == nil, settings.autoAISyncLyrics {
                lyricsService.autoRecognizeIfAuthorizedAndNeeded(
                    for: item,
                    playbackTime: mediaManager.currentTime,
                    equalizerPlayer: mediaManager.equalizerPlayer,
                    isEQPlaying: mediaManager.equalizerPlayer.isPlaying,
                    playbackRate: mediaManager.playbackRate
                )
            }
        }
        .onChange(of: mediaManager.currentTime) { _, newTime in
            syncClockSnapshot(explicitTime: newTime)
        }
        .onChange(of: mediaManager.isPlaying) { _, _ in
            syncClockSnapshot()
        }
    }

    // MARK: - Top AI Status Banner (Passive Only)

    @ViewBuilder
    private var aiStatusHeaderBar: some View {
        let statusMsg = lyricsService.aiErrorMessage ?? lyricsService.aiStatusMessage
        let savedInfo = lyricsService.lastRecognizedTrackInfo
        let showSavedBanner = savedInfo?.relativePath == item.relativePath && savedInfo?.wasAutoSaved == true

        if (statusMsg != nil && !(statusMsg?.isEmpty ?? true)) || showSavedBanner {
            VStack(spacing: 6) {
                if let msg = statusMsg, !msg.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: lyricsService.aiErrorMessage != nil ? "exclamationmark.triangle.fill" : "sparkles")
                            .font(.caption2)
                            .foregroundStyle(lyricsService.aiErrorMessage != nil ? .orange : .green)
                        Text(msg)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if showSavedBanner, let info = savedInfo {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text("Artist DB & Wrapped Confirmed: \(info.artistName) — \(info.songTitle)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
        }
    }

    // MARK: - Main Lyrics Scroll View

    private func lyricsScrollContent(
        lyrics: ResolvedTrackLyrics,
        effectiveTime: Double,
        activeIndex: Int?
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: lyrics.isTimeSynced ? 22 : 16) {
                    Color.clear
                        .frame(height: 28)
                        .id("lyrics-top")

                    ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { idx, line in
                        let isActive = (activeIndex == idx)
                        let distance = activeIndex.map { abs(idx - $0) } ?? 0
                        let isPast = activeIndex.map { idx < $0 } ?? false

                        Group {
                            if line.isInstrumentalBreak {
                                instrumentalDotsRow(
                                    line: line,
                                    isActive: isActive,
                                    isPast: isPast,
                                    effectiveTime: effectiveTime
                                )
                                .onTapGesture {
                                    seekToLine(line, offset: lyrics.syncedOffsetSeconds, tempoScale: lyrics.tempoScale)
                                }
                            } else {
                                lyricLineButton(
                                    line: line,
                                    lyrics: lyrics,
                                    isActive: isActive,
                                    isPast: isPast,
                                    distance: distance,
                                    effectiveTime: effectiveTime
                                )
                            }
                        }
                        .id(line.id)
                    }

                    lyricsFooterView(lyrics: lyrics)
                        .padding(.top, 24)
                        .padding(.bottom, 70)
                }
                .padding(.horizontal, 24)
            }
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 26)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 36)
                }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { _ in
                        markUserScrolling()
                    }
            )
            .onChange(of: activeIndex) { _, newIdx in
                guard lyrics.isTimeSynced, !isUserScrolling, let newIdx,
                      lyrics.lines.indices.contains(newIdx) else { return }
                let targetID = lyrics.lines[newIdx].id
                withAnimation(.spring(response: 0.52, dampingFraction: 0.86)) {
                    proxy.scrollTo(targetID, anchor: UnitPoint(x: 0.5, y: 0.28))
                }
            }
            .onChange(of: isUserScrolling) { _, scrolling in
                guard !scrolling, lyrics.isTimeSynced, let activeIndex,
                      lyrics.lines.indices.contains(activeIndex) else { return }
                let targetID = lyrics.lines[activeIndex].id
                withAnimation(.spring(response: 0.48, dampingFraction: 0.85)) {
                    proxy.scrollTo(targetID, anchor: UnitPoint(x: 0.5, y: 0.28))
                }
            }
            .onAppear {
                if lyrics.isTimeSynced, let activeIndex, lyrics.lines.indices.contains(activeIndex) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        proxy.scrollTo(lyrics.lines[activeIndex].id, anchor: UnitPoint(x: 0.5, y: 0.28))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func lyricLineButton(
        line: SyncedLyricLine,
        lyrics: ResolvedTrackLyrics,
        isActive: Bool,
        isPast: Bool,
        distance: Int,
        effectiveTime: Double
    ) -> some View {
        let baseOpacity: Double = {
            if !lyrics.isTimeSynced { return 0.90 }
            if isActive { return 1.0 }
            if isUserScrolling { return 0.72 }
            if isPast { return 0.30 }
            return distance == 1 ? 0.50 : 0.36
        }()

        let blurRadius: CGFloat = {
            guard lyrics.isTimeSynced, !isUserScrolling, !isActive else { return 0 }
            return min(2.4, CGFloat(distance) * 0.55)
        }()

        let scale: CGFloat = (!lyrics.isTimeSynced || isActive) ? 1.0 : 0.94

        Button {
            if lyrics.isTimeSynced {
                seekToLine(line, offset: lyrics.syncedOffsetSeconds, tempoScale: lyrics.tempoScale)
            }
        } label: {
            Group {
                if lyrics.isTimeSynced && isActive && !line.words.isEmpty {
                    wordHighlightedText(words: line.words, effectiveTime: effectiveTime)
                } else {
                    Text(line.text)
                        .foregroundColor(.white.opacity(baseOpacity))
                }
            }
            .font(.system(size: lyrics.isTimeSynced ? 29 : 23, weight: .bold, design: .default))
            .lineSpacing(4)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .shadow(color: isActive ? .white.opacity(0.24) : .clear, radius: isActive ? 10 : 0)
            .scaleEffect(scale, anchor: .leading)
            .blur(radius: blurRadius)
            .animation(.spring(response: 0.38, dampingFraction: 0.84), value: isActive)
            .animation(.easeOut(duration: 0.2), value: isUserScrolling)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if lyrics.isTimeSynced {
                Button {
                    seekToLine(line, offset: lyrics.syncedOffsetSeconds, tempoScale: lyrics.tempoScale)
                } label: {
                    Label("Play from Here", systemImage: "play.fill")
                }
            }
            Button {
                UIPasteboard.general.string = line.text
                showCopiedToast("Copied lyric line")
            } label: {
                Label("Copy Line", systemImage: "doc.on.doc")
            }
            Button {
                let fullText = lyrics.lines
                    .filter { !$0.isInstrumentalBreak && !$0.text.isEmpty }
                    .map(\.text)
                    .joined(separator: "\n")
                UIPasteboard.general.string = fullText
                showCopiedToast("Copied full lyrics")
            } label: {
                Label("Copy Full Lyrics", systemImage: "text.alignleft")
            }
        }
    }

    private func wordHighlightedText(words: [LyricWordTiming], effectiveTime: Double) -> Text {
        words.enumerated().reduce(Text("")) { partial, pair in
            let (idx, word) = pair
            let prefixSpace = idx == 0 ? "" : " "
            let progress: Double
            if effectiveTime >= word.endTime {
                progress = 1.0
            } else if effectiveTime <= word.startTime {
                progress = 0.0
            } else {
                let span = max(0.05, word.endTime - word.startTime)
                progress = min(1.0, max(0.0, (effectiveTime - word.startTime) / span))
            }
            let wordOpacity = 0.44 + 0.56 * progress
            return partial + Text(prefixSpace + word.text)
                .foregroundColor(.white.opacity(wordOpacity))
        }
    }

    private func instrumentalDotsRow(
        line: SyncedLyricLine,
        isActive: Bool,
        isPast: Bool,
        effectiveTime: Double
    ) -> some View {
        let span = max(0.5, line.endTime - line.startTime)
        let frac = isActive ? min(1.0, max(0.0, (effectiveTime - line.startTime) / span)) : (isPast ? 1.0 : 0.0)
        return HStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { dotIdx in
                let threshold = Double(dotIdx) / 3.0
                let dotLevel = isActive
                    ? min(1.0, max(0.28, (frac - threshold) * 3.0 + 0.35))
                    : (isPast ? 0.22 : 0.35)
                let dotScale = (isActive && frac >= threshold && frac < threshold + 0.40) ? 1.25 : 1.0
                Circle()
                    .fill(.white.opacity(dotLevel))
                    .frame(width: 10, height: 10)
                    .scaleEffect(dotScale)
            }
            Spacer()
        }
        .padding(.vertical, isActive ? 10 : 4)
        .opacity(isPast && !isUserScrolling ? 0.35 : 1.0)
        .animation(.easeInOut(duration: 0.25), value: isActive)
    }

    private func lyricsFooterView(lyrics: ResolvedTrackLyrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
                .overlay(.white.opacity(0.18))

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lyrics.sourceLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    if let attr = lyrics.attributionText, !attr.isEmpty {
                        Text(attr)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    if lyrics.isTimeSynced && abs(lyrics.syncedOffsetSeconds) > 0.01 {
                        Text(String(format: "Timing offset: %+.2fs", lyrics.syncedOffsetSeconds))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                Spacer()
            }
        }
    }

    private func pickRandomTikTokGif() {
        randomGifURL = tiktokMedia.randomGifURL(excluding: randomGifURL)
    }

    private var emptyOrErrorLyricsView: some View {
        VStack(spacing: 16) {
            Text("No lyrics for first time listen")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if let gifURL = randomGifURL ?? tiktokMedia.randomGifURL() {
                AnimatedTikTokImageView(url: gifURL, contentMode: .scaleAspectFit)
                    .frame(width: 220, height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                    .onTapGesture {
                        AppHaptics.light()
                        pickRandomTikTokGif()
                    }
            }

            if wholeSongAI.isListening(to: item) {
                VStack(spacing: 6) {
                    ProgressView(value: max(0.02, wholeSongAI.progressFraction))
                        .tint(.white)
                        .frame(maxWidth: 220)
                    Text(wholeSongAI.statusMessage ?? "AI listening to whole song...")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 2)
            } else if lyricsService.isAIRecognizing {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                    Text(lyricsService.aiStatusMessage ?? "Analyzing audio and syncing lyrics...")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Playback Clock Interpolation & Helpers

    private func syncClockSnapshot(explicitTime: Double? = nil) {
        lastSyncWallTime = .now
        lastSyncPlaybackTime = explicitTime ?? mediaManager.currentTime
    }

    private func interpolatedPlaybackTime(at now: Date, offset: Double, tempoScale: Double = 1.0) -> Double {
        let rawTime: Double
        if mediaManager.isPlaying {
            let dt = max(0, min(1.5, now.timeIntervalSince(lastSyncWallTime)))
            rawTime = lastSyncPlaybackTime + dt * Double(mediaManager.playbackRate)
        } else {
            rawTime = mediaManager.currentTime
        }
        return rawTime * tempoScale + offset
    }

    private func activeLineIndex(in lines: [SyncedLyricLine], at effectiveTime: Double) -> Int? {
        var bestIdx: Int?
        for (idx, line) in lines.enumerated() where line.startTime >= 0 {
            if effectiveTime >= line.startTime - 0.12 {
                bestIdx = idx
            } else {
                break
            }
        }
        return bestIdx
    }

    private func seekToLine(_ line: SyncedLyricLine, offset: Double, tempoScale: Double = 1.0) {
        AppHaptics.light()
        let target = max(0, (line.startTime - offset) / max(0.25, tempoScale))
        mediaManager.seek(to: target)
        if !mediaManager.isPlaying {
            mediaManager.resume()
        }
        lastSyncPlaybackTime = target
        lastSyncWallTime = .now
        isUserScrolling = false
        resumeAutoScrollTask?.cancel()
    }

    private func markUserScrolling() {
        if !isUserScrolling {
            isUserScrolling = true
        }
        resumeAutoScrollTask?.cancel()
        resumeAutoScrollTask = Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            isUserScrolling = false
        }
    }

    private func showCopiedToast(_ text: String) {
        withAnimation { copiedBannerText = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation {
                if copiedBannerText == text { copiedBannerText = nil }
            }
        }
    }
}
