import SwiftUI

struct WrappedDashboardSheet: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(ListeningWrappedService.self) private var wrapped
    @Environment(\.dismiss) private var dismiss

    var initialStartStory: Bool = false

    @State private var selectedYear: Int? = Calendar.current.component(.year, from: .now)
    @State private var searchText = ""
    @State private var showStoryPresentation = false
    @State private var isPremiereMode = false
    @State private var didAutoLaunchStory = false
    @State private var editingArtist: WrappedArtistRanking?
    @State private var renameArtistInput = ""
    @State private var sharePosterURL: URL?

    private var report: WrappedSummaryReport {
        _ = wrapped.lastUpdatedTick
        return wrapped.report(forYear: selectedYear)
    }

    private var filteredArtists: [WrappedArtistRanking] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return report.allArtists }
        return report.allArtists.filter {
            $0.canonicalName.localizedCaseInsensitiveContains(trimmed) ||
                ($0.genre?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    var body: some View {
        @Bindable var wrapped = wrapped

        NavigationStack {
            List {
                yearPickerAndHeroSection
                statsGridSection

                if !report.allArtists.isEmpty {
                    topArtistsSection
                }

                if !report.topSongs.isEmpty {
                    topSongsSection
                }

                if !report.topGenres.isEmpty || report.totalSeconds > 0 {
                    genresAndMonthsSection
                }

                settingsAndDatabaseSection(notificationsOn: $wrapped.notificationsEnabled)
            }
            .listStyle(.insetGrouped)
            .applyAppTheme()
            .navigationTitle("Listening Wrapped")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Filter tracked artists")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }

                if let sharePosterURL {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: sharePosterURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .modifier(
                WrappedDashboardPresentationModifier(
                    selectedYear: $selectedYear,
                    showStoryPresentation: $showStoryPresentation,
                    isPremiereMode: $isPremiereMode,
                    didAutoLaunchStory: $didAutoLaunchStory,
                    editingArtist: $editingArtist,
                    renameArtistInput: $renameArtistInput,
                    sharePosterURL: $sharePosterURL,
                    initialStartStory: initialStartStory,
                    report: report
                )
            )
        }
    }

    // MARK: - Sections

    private var yearPickerAndHeroSection: some View {
        Section {
            Picker("Scope", selection: $selectedYear) {
                ForEach(wrapped.availableYears, id: \.self) { yr in
                    Text("\(String(yr)) Wrapped").tag(Int?.some(yr))
                }
                Text("All Time").tag(Int?.none)
            }
            .pickerStyle(.segmented)

            WrappedHeroCardView(
                report: report,
                daysUntilDec1: ListeningWrappedService.daysUntilDecemberFirst(),
                isDecRevealActive: ListeningWrappedService.isDecemberRevealActive(),
                onPlayStory: {
                    isPremiereMode = ListeningWrappedService.isDecemberRevealActive()
                    showStoryPresentation = true
                },
                onPreviewPremiere: {
                    isPremiereMode = true
                    showStoryPresentation = true
                }
            )
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        }
    }

    private var statsGridSection: some View {
        Section("Year Overview") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                WrappedStatTile(
                    title: "Time Listened",
                    value: report.formattedDurationHero,
                    icon: "clock.fill",
                    tint: .purple
                )
                WrappedStatTile(
                    title: "Total Streams",
                    value: "\(report.totalPlays)",
                    icon: "play.circle.fill",
                    tint: .pink
                )
                WrappedStatTile(
                    title: "Artists Heard",
                    value: "\(report.namedArtists.count)",
                    icon: "music.mic",
                    tint: .blue
                )
                WrappedStatTile(
                    title: "Longest Streak",
                    value: "\(report.longestStreakDays)d (\(report.activeDaysCount)d active)",
                    icon: "flame.fill",
                    tint: .orange
                )
            }
            .padding(.vertical, 4)

            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.indigo.opacity(0.16))
                        .frame(width: 42, height: 42)
                    Image(systemName: report.personaSystemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.indigo)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.personaTitle)
                        .font(.subheadline.weight(.bold))
                    Text(report.personaSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var topArtistsSection: some View {
        Section("Top Artists") {
            let maxSec = max(1, report.allArtists.first?.totalSeconds ?? 1)
            ForEach(Array(filteredArtists.enumerated()), id: \.element.id) { index, artist in
                let actualRank = (report.allArtists.firstIndex(where: { $0.id == artist.id }) ?? index) + 1
                NavigationLink {
                    WrappedArtistDetailView(artist: artist, yearLabel: report.scopeLabel)
                } label: {
                    WrappedArtistRowView(
                        rank: actualRank,
                        artist: artist,
                        progress: artist.totalSeconds / maxSec
                    )
                }
                .contextMenu {
                    Button {
                        renameArtistInput = artist.canonicalName == "Unknown Artist" ? "" : artist.canonicalName
                        editingArtist = artist
                    } label: {
                        Label("Assign / Merge Artist Name", systemImage: "pencil")
                    }
                }
            }
        }
    }

    private var topSongsSection: some View {
        Section("Top Songs") {
            ForEach(Array(report.topSongs.prefix(15).enumerated()), id: \.element.id) { idx, song in
                HStack(spacing: 12) {
                    Text("#\(idx + 1)")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(idx < 3 ? Color.orange : Color.secondary)
                        .frame(width: 28, alignment: .leading)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("\(song.primaryArtist) • \(song.playCount) streams • \(ListeningWrappedService.formatHoursMinutes(song.totalSeconds))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if let rel = song.relativePath,
                       let localItem = mediaManager.items.first(where: { $0.relativePath == rel }) {
                        Button {
                            mediaManager.play(localItem)
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var genresAndMonthsSection: some View {
        Section("Genres & Monthly Activity") {
            if !report.topGenres.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Top Genres")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    ForEach(report.topGenres.prefix(5), id: \.genre) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(item.genre)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text("\(Int(item.percentage.rounded()))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: min(1.0, max(0, item.percentage / 100.0)))
                                .tint(.purple)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            WrappedMonthlyBarChart(
                monthlyBreakdown: report.monthlyBreakdown,
                peakMonthName: report.peakMonth?.name,
                peakHourLabel: report.peakHourLabel
            )
            .padding(.vertical, 4)
        }
    }

    private func settingsAndDatabaseSection(notificationsOn: Binding<Bool>) -> some View {
        Section("December 1st Drop & Artist Database") {
            Toggle(isOn: notificationsOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("December 1st Wrapped Reminder")
                        .font(.subheadline.weight(.medium))
                    Text("Notifies you every Dec 1st at 9 AM with your #1 Artist of the Year")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            NavigationLink {
                ArtistCatalogBrowserView()
            } label: {
                HStack {
                    Label("Major Artists Database", systemImage: "music.note.house.fill")
                    Spacer()
                    Text("\(ArtistDatabase.totalCatalogCount) Artists")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Dashboard Subviews

private struct WrappedHeroCardView: View {
    let report: WrappedSummaryReport
    let daysUntilDec1: Int
    let isDecRevealActive: Bool
    let onPlayStory: () -> Void
    let onPreviewPremiere: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(report.scopeLabel.uppercased())
                    .font(.caption.weight(.heavy))
                    .tracking(1.2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.22), in: Capsule())

                Spacer()

                Text(isDecRevealActive ? "DEC 1 REVEAL UNLOCKED" : "DEC 1 IN \(daysUntilDec1)D")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.25), in: Capsule())
            }
            .foregroundStyle(.white)

            if let hero = report.heroTopArtist {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isDecRevealActive ? "Your #1 Most Listened Artist" : "Currently #1 This Year")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(hero.canonicalName)
                        .font(.title.weight(.black))
                        .foregroundStyle(.white)
                    Text("\(ListeningWrappedService.formatHoursMinutes(hero.totalSeconds)) • \(hero.playCount) streams • \(Int(hero.sharePercentage.rounded()))% of your listening")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.92))
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your Music Story Starts Here")
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(.white)
                    Text("Play songs or music videos in the app to track your favorite artists live toward the December 1st reveal.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.9))
                }
            }

            HStack(spacing: 10) {
                Button(action: onPlayStory) {
                    Label("Play Wrapped Story", systemImage: "sparkles")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)

                if !isDecRevealActive {
                    Button(action: onPreviewPremiere) {
                        Label("Preview Dec 1", systemImage: "calendar.badge.clock")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color(red: 0.42, green: 0.12, blue: 0.78), Color(red: 0.90, green: 0.19, blue: 0.50), Color.orange],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }
}

private struct WrappedStatTile: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct WrappedArtistRowView: View {
    let rank: Int
    let artist: WrappedArtistRanking
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text("#\(rank)")
                    .font(.headline.weight(.heavy).monospacedDigit())
                    .foregroundStyle(rankColor)
                    .frame(width: 32, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(artist.canonicalName)
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                        if let genre = artist.genre {
                            Text(genre)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.14), in: Capsule())
                                .foregroundStyle(.purple)
                                .lineLimit(1)
                        }
                    }

                    Text("\(ListeningWrappedService.formatHoursMinutes(artist.totalSeconds)) • \(artist.playCount) streams (\(Int(artist.sharePercentage.rounded()))%)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            ProgressView(value: min(1.0, max(0.02, progress)))
                .tint(rankColor)
        }
        .padding(.vertical, 3)
    }

    private var rankColor: Color {
        switch rank {
        case 1: return .yellow
        case 2: return .orange
        case 3: return .pink
        default: return .accentColor
        }
    }
}

private struct WrappedMonthlyBarChart: View {
    let monthlyBreakdown: [(month: Int, label: String, seconds: Double)]
    let peakMonthName: String?
    let peakHourLabel: String

    var body: some View {
        let peakVal = max(1, monthlyBreakdown.map(\.seconds).max() ?? 1)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Monthly Listening")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(peakHourLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.indigo)
            }

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(monthlyBreakdown, id: \.month) { entry in
                    let heightFrac = entry.seconds > 0 ? max(0.1, entry.seconds / peakVal) : 0.04
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(entry.seconds > 0 ? Color.pink : Color.secondary.opacity(0.2))
                            .frame(height: 54 * heightFrac)
                        Text(String(entry.label.prefix(1)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 74, alignment: .bottom)

            if let peakMonthName {
                Text("Biggest Month: \(peakMonthName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.pink)
            }
        }
    }
}

// MARK: - Artist Detail & Merge

private struct WrappedArtistDetailView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(ListeningWrappedService.self) private var wrapped
    @Environment(\.dismiss) private var dismiss

    let artist: WrappedArtistRanking
    let yearLabel: String

    @State private var showMergeAlert = false
    @State private var mergedName = ""

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(artist.canonicalName)
                        .font(.title2.weight(.heavy))
                    if let genre = artist.genre {
                        Text(genre)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.purple.opacity(0.16), in: Capsule())
                            .foregroundStyle(.purple)
                    }
                    Text("\(ListeningWrappedService.formatHoursMinutes(artist.totalSeconds)) across \(artist.playCount) streams in \(yearLabel)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                Button {
                    mergedName = artist.canonicalName == "Unknown Artist" ? "" : artist.canonicalName
                    showMergeAlert = true
                } label: {
                    Label("Assign or Merge Artist Name", systemImage: "pencil.and.outline")
                }
            }

            Section("Songs Listened By \(artist.canonicalName)") {
                ForEach(Array(artist.trackEntries.enumerated()), id: \.offset) { idx, entry in
                    HStack(spacing: 12) {
                        Text("#\(idx + 1)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text("\(ListeningWrappedService.formatHoursMinutes(entry.seconds)) • \(entry.plays) streams")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let rel = entry.relativePath,
                           let localItem = mediaManager.items.first(where: { $0.relativePath == rel }) {
                            Button {
                                mediaManager.play(localItem)
                            } label: {
                                Image(systemName: "play.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .applyAppTheme()
        .navigationTitle(artist.canonicalName)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Assign or Merge Artist", isPresented: $showMergeAlert) {
            TextField("Artist name (e.g. Drake)", text: $mergedName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                wrapped.renameOrMergeArtist(oldKey: artist.normalizedKey, to: mergedName)
                dismiss()
            }
        } message: {
            Text("Moves all listening time from \"\(artist.canonicalName)\" to the specified artist.")
        }
    }
}

// MARK: - Built-in Major Artist Catalog Browser

private struct ArtistCatalogBrowserView: View {
    @State private var query = ""

    private var entries: [ArtistCatalogEntry] {
        ArtistDatabase.searchCatalog(query: query, limit: 120)
    }

    var body: some View {
        List(entries, id: \.canonicalName) { entry in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.canonicalName)
                        .font(.subheadline.weight(.semibold))
                    if !entry.aliases.isEmpty {
                        Text("Also matches: \(entry.aliases.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(entry.genre)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
        }
        .listStyle(.plain)
        .applyAppTheme()
        .navigationTitle("Artist Catalog (\(ArtistDatabase.totalCatalogCount))")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search artists or genres")
    }
}

// MARK: - Full-Screen Story Wrapped Experience

struct WrappedStoryView: View {
    @Environment(ListeningWrappedService.self) private var wrapped

    let year: Int?
    let isDecemberPremiere: Bool
    @Binding var isPresented: Bool

    @State private var currentSlide = 0
    @State private var sharePosterURL: URL?

    private let slideCount = 6

    private var report: WrappedSummaryReport {
        _ = wrapped.lastUpdatedTick
        return wrapped.report(forYear: year)
    }

    var body: some View {
        ZStack {
            slideGradient(for: currentSlide)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(0..<slideCount, id: \.self) { idx in
                        Capsule()
                            .fill(idx <= currentSlide ? Color.white : Color.white.opacity(0.3))
                            .frame(height: 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                HStack {
                    Text(isDecemberPremiere ? "DECEMBER 1 PREMIERE" : report.scopeLabel.uppercased())
                        .font(.caption.weight(.black))
                        .tracking(1.1)
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Button {
                        finishStory()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.88))
                    }
                }
                .padding(.horizontal, 18)

                TabView(selection: $currentSlide) {
                    introSlide.tag(0)
                    topArtistCrownSlide.tag(1)
                    topFiveArtistsSlide.tag(2)
                    topSongsAndGenreSlide.tag(3)
                    rhythmAndPersonaSlide.tag(4)
                    finalPosterSlide.tag(5)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            currentSlide = max(0, currentSlide - 1)
                        }
                    } label: {
                        Image(systemName: "chevron.left.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(currentSlide == 0 ? 0.25 : 0.9))
                    }
                    .disabled(currentSlide == 0)

                    Spacer()

                    Text("\(currentSlide + 1) / \(slideCount)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))

                    Spacer()

                    Button {
                        if currentSlide < slideCount - 1 {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                currentSlide += 1
                            }
                        } else {
                            finishStory()
                        }
                    } label: {
                        Image(systemName: currentSlide < slideCount - 1 ? "chevron.right.circle.fill" : "checkmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
        }
        .onAppear {
            sharePosterURL = WrappedPosterExporter.renderPosterURL(for: report)
        }
    }

    private func finishStory() {
        let yr = year ?? Calendar.current.component(.year, from: .now)
        if isDecemberPremiere {
            wrapped.markPremiereViewed(for: yr)
        }
        isPresented = false
    }

    private var introSlide: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text(isDecemberPremiere ? "December 1st\nHas Arrived." : "Your Year\nin Sound.")
                .font(.system(size: 40, weight: .black))
                .foregroundStyle(.white)

            Text("You pressed play \(report.totalPlays) times across \(report.activeDaysCount) days.")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))

            VStack(alignment: .leading, spacing: 6) {
                Text(report.formattedDurationHero)
                    .font(.system(size: 52, weight: .black))
                    .foregroundStyle(.yellow)
                Text("Total listening time in \(report.scopeLabel)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
    }

    private var topArtistCrownSlide: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "crown.fill")
                .font(.system(size: 54))
                .foregroundStyle(.yellow)

            if let hero = report.heroTopArtist {
                Text("YOUR #1 ARTIST OF THE YEAR")
                    .font(.caption.weight(.black))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.85))

                Text(hero.canonicalName)
                    .font(.system(size: 42, weight: .black))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)

                if let genre = hero.genre {
                    Text(genre)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.22), in: Capsule())
                        .foregroundStyle(.white)
                }

                VStack(spacing: 6) {
                    Text("\(Int(hero.sharePercentage.rounded()))% of your total listening")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.yellow)
                    Text("\(ListeningWrappedService.formatHoursMinutes(hero.totalSeconds)) • \(hero.playCount) streams")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    if let topSong = hero.topTrackTitle {
                        Text("Top Song: \"\(topSong)\"")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.top, 4)
                    }
                }
            } else {
                Text("No Tracks Played Yet")
                    .font(.title.weight(.black))
                    .foregroundStyle(.white)
                Text("Play songs or videos offline to crown your #1 Artist on December 1st.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private var topFiveArtistsSlide: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text("Your Top 5 Artists")
                .font(.system(size: 32, weight: .black))
                .foregroundStyle(.white)

            if report.namedArtists.isEmpty {
                Text("Keep listening to populate your Top 5 leaderboard.")
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                let topList = Array(report.namedArtists.prefix(5))
                let maxSec = max(1, topList.first?.totalSeconds ?? 1)
                ForEach(Array(topList.enumerated()), id: \.element.id) { idx, artist in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(idx + 1). \(artist.canonicalName)")
                                .font(.title3.weight(.heavy))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Spacer()
                            Text(ListeningWrappedService.formatHoursMinutes(artist.totalSeconds))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.yellow)
                        }
                        GeometryReader { geo in
                            Capsule()
                                .fill(.white.opacity(0.24))
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(.white)
                                        .frame(width: max(12, geo.size.width * CGFloat(artist.totalSeconds / maxSec)))
                                }
                        }
                        .frame(height: 8)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private var topSongsAndGenreSlide: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text("Your Top Songs")
                .font(.system(size: 32, weight: .black))
                .foregroundStyle(.white)

            if let topGenre = report.topGenres.first {
                Text("Top Sound: \(topGenre.genre) (\(Int(topGenre.percentage.rounded()))%)")
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.2), in: Capsule())
                    .foregroundStyle(.yellow)
            }

            if report.topSongs.isEmpty {
                Text("No played songs recorded yet.")
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                ForEach(Array(report.topSongs.prefix(5).enumerated()), id: \.element.id) { idx, song in
                    HStack(spacing: 12) {
                        Text("\(idx + 1)")
                            .font(.title2.weight(.black).monospacedDigit())
                            .foregroundStyle(.yellow)
                            .frame(width: 28, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title)
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("\(song.primaryArtist) • \(song.playCount) streams")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
    }

    private var rhythmAndPersonaSlide: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Image(systemName: report.personaSystemImage)
                .font(.system(size: 48))
                .foregroundStyle(.yellow)

            Text("LISTENING PERSONA")
                .font(.caption.weight(.black))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.85))

            Text(report.personaTitle)
                .font(.system(size: 34, weight: .black))
                .foregroundStyle(.white)

            Text(report.personaSubtitle)
                .font(.headline.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))

            Divider().background(.white.opacity(0.3))

            VStack(alignment: .leading, spacing: 6) {
                Text("Peak Listening Window: \(report.peakHourLabel)")
                if let peak = report.peakMonth {
                    Text("Biggest Music Month: \(peak.name) (\(ListeningWrappedService.formatHoursMinutes(peak.seconds)))")
                }
                Text("Longest Listening Streak: \(report.longestStreakDays) days")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
    }

    private var finalPosterSlide: some View {
        VStack(spacing: 16) {
            WrappedPosterRenderCard(report: report)
                .scaleEffect(0.76)
                .frame(height: 410)

            HStack(spacing: 12) {
                if let sharePosterURL {
                    ShareLink(item: sharePosterURL) {
                        Label("Share Wrapped Card", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(.white, in: Capsule())
                            .foregroundStyle(.purple)
                    }
                }

                Button("Finish") {
                    finishStory()
                }
                .font(.subheadline.weight(.bold))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.white.opacity(0.22), in: Capsule())
                .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
    }

    private func slideGradient(for slide: Int) -> LinearGradient {
        let palettes: [[Color]] = [
            [Color(red: 0.12, green: 0.08, blue: 0.35), Color(red: 0.56, green: 0.14, blue: 0.65)],
            [Color(red: 0.72, green: 0.10, blue: 0.42), Color(red: 0.96, green: 0.44, blue: 0.14)],
            [Color(red: 0.08, green: 0.25, blue: 0.52), Color(red: 0.14, green: 0.62, blue: 0.56)],
            [Color(red: 0.35, green: 0.10, blue: 0.55), Color(red: 0.85, green: 0.20, blue: 0.45)],
            [Color(red: 0.10, green: 0.12, blue: 0.25), Color(red: 0.36, green: 0.22, blue: 0.72)],
            [Color(red: 0.16, green: 0.06, blue: 0.32), Color(red: 0.78, green: 0.16, blue: 0.48)]
        ]
        let cols = palettes[slide % palettes.count]
        return LinearGradient(colors: cols, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Shareable Poster Card & Renderer

private struct WrappedPosterRenderCard: View {
    let report: WrappedSummaryReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(report.scopeLabel.uppercased())
                    .font(.caption.weight(.black))
                    .tracking(1.5)
                    .foregroundStyle(.yellow)
                Spacer()
                Text("MUSICPLAYER")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white.opacity(0.75))
            }

            if let hero = report.heroTopArtist {
                VStack(alignment: .leading, spacing: 2) {
                    Text("#1 TOP ARTIST")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.75))
                    Text(hero.canonicalName)
                        .font(.title.weight(.black))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("TOP ARTISTS")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.yellow)
                    ForEach(Array(report.namedArtists.prefix(5).enumerated()), id: \.element.id) { idx, a in
                        Text("\(idx + 1). \(a.canonicalName)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    if report.namedArtists.isEmpty {
                        Text("Press play to track")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 5) {
                    Text("TOP SONGS")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.yellow)
                    ForEach(Array(report.topSongs.prefix(5).enumerated()), id: \.element.id) { idx, s in
                        Text("\(idx + 1). \(s.title)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    if report.topSongs.isEmpty {
                        Text("No streams yet")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().background(.white.opacity(0.25))

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MINUTES LISTENED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("\(report.totalMinutes)")
                        .font(.title2.weight(.black))
                        .foregroundStyle(.yellow)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("TOP GENRE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(report.topGenres.first?.genre ?? report.personaTitle)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(22)
        .frame(width: 360)
        .background(
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.08, blue: 0.38), Color(red: 0.78, green: 0.16, blue: 0.48), Color.orange],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.25), lineWidth: 1)
        }
    }
}

private enum WrappedPosterExporter {
    @MainActor
    static func renderPosterURL(for report: WrappedSummaryReport) -> URL? {
        let poster = WrappedPosterRenderCard(report: report)
        let renderer = ImageRenderer(content: poster)
        renderer.scale = 3.0
        guard let image = renderer.uiImage,
              let data = image.pngData() else {
            return nil
        }
        let fileName = report.year.map { "MusicPlayer-Wrapped-\($0).png" } ?? "MusicPlayer-AllTime-Wrapped.png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? data.write(to: url, options: [.atomic])
        return url
    }
}

private struct WrappedDashboardPresentationModifier: ViewModifier {
    @Environment(ListeningWrappedService.self) private var wrapped

    @Binding var selectedYear: Int?
    @Binding var showStoryPresentation: Bool
    @Binding var isPremiereMode: Bool
    @Binding var didAutoLaunchStory: Bool
    @Binding var editingArtist: WrappedArtistRanking?
    @Binding var renameArtistInput: String
    @Binding var sharePosterURL: URL?

    let initialStartStory: Bool
    let report: WrappedSummaryReport

    func body(content: Content) -> some View {
        content
            .onAppear {
                sharePosterURL = WrappedPosterExporter.renderPosterURL(for: report)
                if initialStartStory && !didAutoLaunchStory {
                    didAutoLaunchStory = true
                    isPremiereMode = ListeningWrappedService.isDecemberRevealActive()
                    showStoryPresentation = true
                }
            }
            .onChange(of: selectedYear) { _, _ in
                sharePosterURL = WrappedPosterExporter.renderPosterURL(for: report)
            }
            .onChange(of: wrapped.lastUpdatedTick) { _, _ in
                sharePosterURL = WrappedPosterExporter.renderPosterURL(for: report)
            }
            .fullScreenCover(isPresented: $showStoryPresentation) {
                WrappedStoryView(
                    year: selectedYear,
                    isDecemberPremiere: isPremiereMode,
                    isPresented: $showStoryPresentation
                )
            }
            .alert("Rename or Merge Artist", isPresented: Binding(
                get: { editingArtist != nil },
                set: { if !$0 { editingArtist = nil } }
            )) {
                TextField("Correct artist name", text: $renameArtistInput)
                Button("Cancel", role: .cancel) { editingArtist = nil }
                Button("Apply") {
                    if let target = editingArtist {
                        wrapped.renameOrMergeArtist(oldKey: target.normalizedKey, to: renameArtistInput)
                    }
                    editingArtist = nil
                }
            } message: {
                Text("Standardizes past plays and merges future plays under this artist name across Wrapped.")
            }
    }
}
