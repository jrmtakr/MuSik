import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ReaderPageSource: Identifiable, Hashable {
    case local(URL)
    case remote(URL)

    var id: String {
        switch self {
        case .local(let url): return "local:\(url.path)"
        case .remote(let url): return "remote:\(url.absoluteString)"
        }
    }

    var url: URL {
        switch self {
        case .local(let url), .remote(let url): return url
        }
    }

    var isLocal: Bool {
        if case .local = self { return true }
        return false
    }
}

struct ImageReaderTarget: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let pages: [ReaderPageSource]
    let initialIndex: Int

    init(title: String, files: [LocalFile], initialIndex: Int = 0) {
        self.title = title
        self.pages = files.map { .local($0.fileURL) }
        self.initialIndex = initialIndex
    }

    init(title: String, remoteURLs: [URL], initialIndex: Int = 0) {
        self.title = title
        self.pages = remoteURLs.map { .remote($0) }
        self.initialIndex = initialIndex
    }
}

struct ImageReaderView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    let target: ImageReaderTarget
    @State private var currentIndex: Int
    @State private var scrollZoomScale: CGFloat = 1.0
    @State private var lastScrollZoomScale: CGFloat = 1.0
    @State private var showHUD = true

    init(target: ImageReaderTarget) {
        self.target = target
        self._currentIndex = State(initialValue: target.initialIndex)
    }

    private var readerBackgroundColor: Color {
        if settings.useCustomBackgroundColor {
            return settings.customBackgroundColor
        }
        return Color.black
    }

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            ZStack(alignment: .bottom) {
                Group {
                    if target.pages.isEmpty {
                        ContentUnavailableView("No Manga Pages", systemImage: "book.pages")
                    } else if settings.readingDirection == .scroll {
                        ScrollViewReader { proxy in
                            ScrollView([.vertical, scrollZoomScale > 1.02 ? .horizontal : []]) {
                                LazyVStack(spacing: 4) {
                                    ForEach(Array(target.pages.enumerated()), id: \.element.id) { idx, page in
                                        ReaderPageImage(page: page)
                                            .id(idx)
                                            .onAppear {
                                                currentIndex = idx
                                                prefetchAdjacentRemotePages(from: idx)
                                            }
                                            .onTapGesture(count: 2) {
                                                withAnimation(.easeInOut(duration: 0.2)) {
                                                    scrollZoomScale = scrollZoomScale > 1.1 ? 1.0 : 2.0
                                                    lastScrollZoomScale = scrollZoomScale
                                                }
                                            }
                                            .onTapGesture(count: 1) {
                                                withAnimation(.easeInOut(duration: 0.18)) {
                                                    showHUD.toggle()
                                                }
                                            }
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .scaleEffect(scrollZoomScale, anchor: .center)
                            }
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        scrollZoomScale = min(max(lastScrollZoomScale * value, 1.0), 3.5)
                                    }
                                    .onEnded { _ in
                                        lastScrollZoomScale = scrollZoomScale
                                    }
                            )
                            .onAppear {
                                if target.initialIndex > 0 {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                        proxy.scrollTo(target.initialIndex, anchor: .top)
                                    }
                                }
                            }
                        }
                        .background(readerBackgroundColor)
                    } else {
                        let isRTL = settings.readingDirection == .mangaRTL
                        TabView(selection: $currentIndex) {
                            ForEach(Array(target.pages.enumerated()), id: \.element.id) { idx, page in
                                ZoomableImagePage(page: page) {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        showHUD.toggle()
                                    }
                                }
                                .environment(\.layoutDirection, .leftToRight)
                                .tag(idx)
                                .onAppear {
                                    prefetchAdjacentRemotePages(from: idx)
                                }
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
                        .background(readerBackgroundColor)
                    }
                }

                if showHUD && target.pages.count > 1 {
                    mangaBottomScrubber
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("\(target.title) (\(min(currentIndex + 1, max(target.pages.count, 1)))/\(target.pages.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Reading Mode", selection: $settings.readingDirection) {
                            ForEach(ReadingDirection.allCases) { dir in
                                Label(
                                    dir.displayTitle,
                                    systemImage: iconForDirection(dir)
                                )
                                .tag(dir)
                            }
                        }
                    } label: {
                        Label(
                            settings.readingDirection.rawValue,
                            systemImage: iconForDirection(settings.readingDirection)
                        )
                    }

                    if target.pages.indices.contains(currentIndex) {
                        let activePage = target.pages[currentIndex]
                        ShareLink(item: activePage.url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }

    private func prefetchAdjacentRemotePages(from index: Int) {
        let upper = min(target.pages.count, index + 4)
        guard index + 1 < upper else { return }
        for nextIdx in (index + 1)..<upper {
            if case .remote(let url) = target.pages[nextIdx] {
                RemoteMangaPageCache.prefetch(url: url)
            }
        }
    }

    private func iconForDirection(_ dir: ReadingDirection) -> String {
        switch dir {
        case .scroll: return "arrow.up.and.down"
        case .page: return "arrow.left.and.right"
        case .mangaRTL: return "character.book.closed.fill.ja"
        }
    }

    private var mangaBottomScrubber: some View {
        let count = target.pages.count
        let isRTL = settings.readingDirection == .mangaRTL
        return VStack(spacing: 6) {
            HStack {
                Button {
                    withAnimation {
                        currentIndex = max(0, currentIndex - 1)
                    }
                } label: {
                    Image(systemName: isRTL ? "chevron.right.circle.fill" : "chevron.left.circle.fill")
                        .font(.title3)
                }
                .disabled(currentIndex <= 0)

                Slider(
                    value: Binding(
                        get: { Double(min(max(currentIndex, 0), max(count - 1, 0))) },
                        set: { currentIndex = Int(round($0)) }
                    ),
                    in: 0...Double(max(count - 1, 1)),
                    step: 1
                )
                .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)

                Button {
                    withAnimation {
                        currentIndex = min(count - 1, currentIndex + 1)
                    }
                } label: {
                    Image(systemName: isRTL ? "chevron.left.circle.fill" : "chevron.right.circle.fill")
                        .font(.title3)
                }
                .disabled(currentIndex >= count - 1)
            }

            HStack {
                Text(settings.readingDirection.displayTitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Page \(min(currentIndex + 1, count)) of \(count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }
}

private enum RemoteMangaPageCache {
    static let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 45
        return c
    }()

    static func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    static func store(_ img: UIImage, for url: URL) {
        cache.setObject(img, forKey: url as NSURL)
    }

    static func prefetch(url: URL) {
        if cache.object(forKey: url as NSURL) != nil { return }
        Task.detached(priority: .utility) {
            var req = URLRequest(url: url)
            req.timeoutInterval = 18
            req.setValue("MuseJRM/1.0", forHTTPHeaderField: "User-Agent")
            req.setValue("https://mangadex.org/", forHTTPHeaderField: "Referer")
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse,
               (200...299).contains(http.statusCode),
               let img = UIImage(data: data) {
                await MainActor.run {
                    store(img, for: url)
                }
            }
        }
    }
}

private struct ReaderPageImage: View {
    let page: ReaderPageSource
    @State private var remoteImage: UIImage?
    @State private var isLoading = false
    @State private var failed = false
    @State private var retryNonce = 0

    var body: some View {
        switch page {
        case .local(let url):
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .frame(height: 240)
            }
        case .remote(let url):
            Group {
                if let img = remoteImage ?? RemoteMangaPageCache.image(for: url) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                } else if failed {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Button("Tap to Retry Page") {
                            failed = false
                            retryNonce &+= 1
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
                        Text("Loading page...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 380)
                }
            }
            .task(id: "\(url.absoluteString)|\(retryNonce)") {
                if let cached = RemoteMangaPageCache.image(for: url) {
                    remoteImage = cached
                    return
                }
                isLoading = true
                failed = false
                defer { isLoading = false }
                var req = URLRequest(url: url)
                req.timeoutInterval = 20
                req.setValue("MuseJRM/1.0", forHTTPHeaderField: "User-Agent")
                req.setValue("https://mangadex.org/", forHTTPHeaderField: "Referer")
                if let (data, resp) = try? await URLSession.shared.data(for: req),
                   let http = resp as? HTTPURLResponse,
                   (200...299).contains(http.statusCode),
                   let img = UIImage(data: data) {
                    RemoteMangaPageCache.store(img, for: url)
                    remoteImage = img
                } else {
                    failed = true
                }
            }
        }
    }
}

private struct ZoomableImagePage: View {
    let page: ReaderPageSource
    var onSingleTap: () -> Void = {}
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                ReaderPageImage(page: page)
                    .frame(width: proxy.size.width * scale, height: proxy.size.height * scale)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scale = scale > 1.1 ? 1.0 : 2.2
                            lastScale = scale
                        }
                    }
                    .onTapGesture(count: 1) {
                        onSingleTap()
                    }
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = min(max(lastScale * value, 1.0), 4.0)
                            }
                            .onEnded { _ in
                                lastScale = scale
                            }
                    )
            }
        }
    }
}

struct TextStoryReaderView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    let file: LocalFile
    @State private var textContent: String = ""

    private var effectiveTextColor: Color {
        if settings.useCustomTextColor {
            return settings.customTextColor
        }
        return settings.readerDarkTheme ? Color(white: 0.9) : Color(white: 0.12)
    }

    private var effectiveBackgroundColor: Color {
        if settings.useCustomBackgroundColor {
            return settings.customBackgroundColor
        }
        return settings.readerDarkTheme
            ? Color(red: 0.08, green: 0.08, blue: 0.1)
            : Color(red: 0.98, green: 0.96, blue: 0.92)
    }

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            ScrollView {
                Text(textContent)
                    .font(.system(size: settings.readerFontSize))
                    .foregroundStyle(effectiveTextColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .textSelection(.enabled)
            }
            .background(effectiveBackgroundColor)
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        settings.readerFontSize = max(12, settings.readerFontSize - 2)
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                    }

                    Button {
                        settings.readerFontSize = min(32, settings.readerFontSize + 2)
                    } label: {
                        Image(systemName: "textformat.size.larger")
                    }

                    Button {
                        settings.readerDarkTheme.toggle()
                    } label: {
                        Image(systemName: settings.readerDarkTheme ? "sun.max.fill" : "moon.fill")
                    }

                    ShareLink(item: file.fileURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .onAppear {
                textContent = loadText()
            }
        }
    }

    private func loadText() -> String {
        guard let data = try? Data(contentsOf: file.fileURL) else {
            return "Unable to read file."
        }
        if file.fileExtension == "rtf",
           let attr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
           ) {
            return attr.string
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? "Unsupported text encoding."
    }
}

struct MangaLibrarySheetView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    enum ReaderHubSection: String, CaseIterable, Identifiable {
        case online = "Online Server"
        case offline = "Offline Library"
        var id: String { rawValue }
    }

    @State private var mangaService = MangaDexService.shared
    @State private var activeSection: ReaderHubSection = .online
    @State private var searchQuery = ""
    @State private var selectedOnlineSeries: OnlineMangaSeries?

    @State private var activeReaderTarget: ImageReaderTarget?
    @State private var activeTextFile: LocalFile?
    @State private var showFolderImporter = false
    @State private var showFileImporter = false

    private var chapters: [(title: String, folderPath: String, files: [LocalFile])] {
        mediaManager.mangaImageChapters()
    }

    private var archives: [LocalFile] {
        mediaManager.otherFiles.filter { $0.isArchive }
    }

    private var stories: [LocalFile] {
        mediaManager.otherFiles.filter { $0.isReadableText }
    }

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            List {
                Section {
                    Picker("Source", selection: $activeSection) {
                        ForEach(ReaderHubSection.allCases) { sec in
                            Text(sec.rawValue).tag(sec)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }

                if activeSection == .online {
                    onlineMangaServerSections
                } else {
                    Section("Reading Mode") {
                        Picker("Direction", selection: $settings.readingDirection) {
                            ForEach(ReadingDirection.allCases) { dir in
                                Text(dir.displayTitle).tag(dir)
                            }
                        }

                        HStack(spacing: 10) {
                            Button {
                                showFolderImporter = true
                            } label: {
                                Label("Import Chapter Folder", systemImage: "folder.badge.plus")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                showFileImporter = true
                            } label: {
                                Label("Import .CBZ / .ZIP / Images", systemImage: "doc.badge.plus")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    }

                    Section("Manga & Image Chapters (\(chapters.count))") {
                        if chapters.isEmpty {
                            Text("No offline chapters yet. Switch to \"Online Server\" to read & download manga right inside MuseJRM, import a folder/.CBZ, or use \"Read Page in Manga Reader\" in Browser.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(chapters, id: \.folderPath) { chapter in
                                Button {
                                    activeReaderTarget = ImageReaderTarget(
                                        title: chapter.title,
                                        files: chapter.files,
                                        initialIndex: 0
                                    )
                                } label: {
                                    HStack(spacing: 12) {
                                        if let first = chapter.files.first,
                                           let img = UIImage(contentsOfFile: first.fileURL.path) {
                                            Image(uiImage: img)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: 48, height: 64)
                                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        } else {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(Color.accentColor.opacity(0.15))
                                                .frame(width: 48, height: 64)
                                                .overlay {
                                                    Image(systemName: "book.pages.fill")
                                                        .foregroundStyle(Color.accentColor)
                                                }
                                        }

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(chapter.title)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text("\(chapter.files.count) \(chapter.files.count == 1 ? "page" : "pages")")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            if !chapter.folderPath.isEmpty {
                                                Text(chapter.folderPath)
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                                    .lineLimit(1)
                                            }
                                        }

                                        Spacer()

                                        Text("Read")
                                            .font(.caption.weight(.bold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    .padding(.vertical, 2)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !archives.isEmpty {
                        Section("Manga & Comic Archives (.CBZ / .ZIP)") {
                            ForEach(archives) { archive in
                                Button {
                                    if let extractedFolder = mediaManager.extractArchive(archive) {
                                        let imgs = mediaManager.imagesRecursive(inFolder: extractedFolder)
                                        if !imgs.isEmpty {
                                            activeReaderTarget = ImageReaderTarget(
                                                title: archive.name,
                                                files: imgs,
                                                initialIndex: 0
                                            )
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "archivebox.fill")
                                            .font(.title3)
                                            .foregroundStyle(.orange)
                                            .frame(width: 36)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(archive.fileName)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.primary)
                                            Text("\(archive.formattedFileSize) • Tap to extract & open in Manga Reader")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "book.pages")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !stories.isEmpty {
                        Section("Stories & Light Novels (.TXT / .MD / .RTF)") {
                            ForEach(stories) { story in
                                Button {
                                    activeTextFile = story
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "doc.text.fill")
                                            .font(.title3)
                                            .foregroundStyle(.teal)
                                            .frame(width: 36)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(story.fileName)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.primary)
                                            Text(story.formattedFileSize)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text("Read")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .applyAppTheme()
            .navigationTitle("Manga & Story Reader")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if activeSection == .online {
                        Button {
                            Task { await mangaService.loadCatalogIfNeeded(force: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await mangaService.loadCatalogIfNeeded()
            }
            .sheet(item: $selectedOnlineSeries) { series in
                OnlineMangaDetailView(manga: series)
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.item, .folder],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    for url in urls {
                        mediaManager.importAnyFile(from: url)
                    }
                }
            }
            .fullScreenCover(item: $activeReaderTarget) { target in
                ImageReaderView(target: target)
            }
            .fullScreenCover(item: $activeTextFile) { file in
                TextStoryReaderView(file: file)
            }
        }
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls {
                    mediaManager.importAnyFile(from: url)
                }
            }
        }
    }

    @ViewBuilder
    private var onlineMangaServerSections: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search free manga (MangaDex)", text: $searchQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await mangaService.searchManga(query: searchQuery) }
                    }
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        mangaService.searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Button("Search") {
                    Task { await mangaService.searchManga(query: searchQuery) }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }

        if mangaService.isSearching {
            Section("Search Results") {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching MangaDex...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if !mangaService.searchResults.isEmpty {
            Section("Search Results (\(mangaService.searchResults.count))") {
                ForEach(mangaService.searchResults) { manga in
                    onlineMangaRow(manga)
                }
            }
        }

        if let err = mangaService.catalogError, mangaService.popularManga.isEmpty {
            Section("Manga Server") {
                VStack(spacing: 10) {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry Connection") {
                        Task { await mangaService.loadCatalogIfNeeded(force: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        } else if mangaService.isLoadingCatalog && mangaService.popularManga.isEmpty {
            Section("Manga Server • MangaDex (Free)") {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Connecting to MangaDex catalog...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            if !mangaService.popularManga.isEmpty {
                Section("Popular Manga") {
                    ForEach(mangaService.popularManga) { manga in
                        onlineMangaRow(manga)
                    }
                }
            }
            if !mangaService.recentManga.isEmpty {
                Section("Latest English Updates") {
                    ForEach(mangaService.recentManga) { manga in
                        onlineMangaRow(manga)
                    }
                }
            }
        }
    }

    private func onlineMangaRow(_ manga: OnlineMangaSeries) -> some View {
        Button {
            selectedOnlineSeries = manga
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: manga.thumbnailURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.16))
                        .overlay {
                            Image(systemName: "book.pages.fill")
                                .foregroundStyle(.orange)
                        }
                }
                .frame(width: 52, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(manga.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let author = manga.authorName, !author.isEmpty {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        if let status = manga.status, !status.isEmpty {
                            Text(status)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                        if !manga.tags.isEmpty {
                            Text(manga.tags.prefix(3).joined(separator: " • "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}

struct OnlineMangaDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    let manga: OnlineMangaSeries
    @State private var mangaService = MangaDexService.shared
    @State private var chapters: [OnlineMangaChapter] = []
    @State private var isLoadingChapters = true
    @State private var ascendingOrder = false
    @State private var loadingChapterID: String?
    @State private var savingChapterID: String?
    @State private var saveProgress: Double = 0
    @State private var statusBanner: String?
    @State private var activeReaderTarget: ImageReaderTarget?

    private var orderedChapters: [OnlineMangaChapter] {
        let readable = chapters.filter(\.isReadableInApp)
        let pool = readable.isEmpty ? chapters : readable
        return ascendingOrder ? pool : Array(pool.reversed())
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        AsyncImage(url: manga.coverURL ?? manga.thumbnailURL) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.orange.opacity(0.18))
                        }
                        .frame(width: 94, height: 136)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        VStack(alignment: .leading, spacing: 6) {
                            Text(manga.title)
                                .font(.headline)
                            if let author = manga.authorName, !author.isEmpty {
                                Text(author)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            if let status = manga.status {
                                Text("Status: \(status)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if !manga.tags.isEmpty {
                                Text(manga.tags.joined(separator: " • "))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                            }

                            if let firstReadable = chapters.first(where: \.isReadableInApp) {
                                Button {
                                    Task { await openChapter(firstReadable) }
                                } label: {
                                    Label("Read \(firstReadable.chapterNumber.map { "Ch. \($0)" } ?? "Ch. 1")", systemImage: "book.pages.fill")
                                        .font(.caption.weight(.bold))
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .padding(.top, 4)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    if !manga.description.isEmpty {
                        Text(manga.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(5)
                    }
                }

                if let statusBanner {
                    Section {
                        Text(statusBanner)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Section {
                    if isLoadingChapters {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading English chapters...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if orderedChapters.isEmpty {
                        Text("No chapters hosted directly on MangaDex for this title. Try searching another release or opening it in the Browser tab.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(orderedChapters) { chapter in
                            HStack(spacing: 10) {
                                Button {
                                    if chapter.isReadableInApp {
                                        Task { await openChapter(chapter) }
                                    } else if let ext = chapter.externalURL {
                                        UIApplication.shared.open(ext)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(chapter.displayLabel)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        HStack(spacing: 8) {
                                            if chapter.isReadableInApp {
                                                Text("\(chapter.pagesCount) pages")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            } else {
                                                Text("External publisher link")
                                                    .font(.caption2)
                                                    .foregroundStyle(.orange)
                                            }
                                            if let grp = chapter.scanlationGroup, !grp.isEmpty {
                                                Text("• \(grp)")
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)

                                if loadingChapterID == chapter.id {
                                    ProgressView()
                                        .controlSize(.small)
                                } else if savingChapterID == chapter.id {
                                    ProgressView(value: saveProgress)
                                        .frame(width: 44)
                                } else if chapter.isReadableInApp {
                                    Button {
                                        Task { await downloadChapterOffline(chapter) }
                                    } label: {
                                        Image(systemName: "arrow.down.circle")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Chapters (\(orderedChapters.count))")
                        Spacer()
                        Button(ascendingOrder ? "Oldest First" : "Newest First") {
                            ascendingOrder.toggle()
                        }
                        .font(.caption2.weight(.semibold))
                    }
                }
            }
            .applyAppTheme()
            .navigationTitle(manga.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                isLoadingChapters = true
                chapters = await mangaService.fetchChapters(for: manga.id)
                isLoadingChapters = false
            }
            .fullScreenCover(item: $activeReaderTarget) { target in
                ImageReaderView(target: target)
            }
        }
    }

    private func openChapter(_ chapter: OnlineMangaChapter) async {
        loadingChapterID = chapter.id
        statusBanner = nil
        let urls = await mangaService.fetchChapterPageURLs(chapterID: chapter.id, preferDataSaver: false)
        loadingChapterID = nil
        guard !urls.isEmpty else {
            statusBanner = "Could not load pages for \(chapter.displayLabel)."
            return
        }
        let chTitle = "\(manga.title) • \(chapter.chapterNumber.map { "Ch. \($0)" } ?? "Oneshot")"
        activeReaderTarget = ImageReaderTarget(title: chTitle, remoteURLs: urls, initialIndex: 0)
    }

    private func downloadChapterOffline(_ chapter: OnlineMangaChapter) async {
        savingChapterID = chapter.id
        saveProgress = 0
        statusBanner = "Downloading \(chapter.displayLabel) for offline reading..."
        let saved = await mangaService.downloadChapterOffline(manga: manga, chapter: chapter) { frac in
            Task { @MainActor in
                saveProgress = frac
            }
        }
        savingChapterID = nil
        statusBanner = saved.isEmpty
            ? "Could not save \(chapter.displayLabel) offline."
            : "Saved \(saved.count) pages offline under Manga/\(manga.title)."
    }
}
