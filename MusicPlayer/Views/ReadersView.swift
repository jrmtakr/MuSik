import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ImageReaderTarget: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let files: [LocalFile]
    let initialIndex: Int
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
                    if target.files.isEmpty {
                        ContentUnavailableView("No Manga Pages", systemImage: "book.pages")
                    } else if settings.readingDirection == .scroll {
                        ScrollViewReader { proxy in
                            ScrollView([.vertical, scrollZoomScale > 1.02 ? .horizontal : []]) {
                                LazyVStack(spacing: 4) {
                                    ForEach(Array(target.files.enumerated()), id: \.element.id) { idx, file in
                                        ReaderPageImage(url: file.fileURL)
                                            .id(idx)
                                            .onAppear {
                                                currentIndex = idx
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
                            ForEach(Array(target.files.enumerated()), id: \.element.id) { idx, file in
                                ZoomableImagePage(url: file.fileURL) {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        showHUD.toggle()
                                    }
                                }
                                .environment(\.layoutDirection, .leftToRight)
                                .tag(idx)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
                        .background(readerBackgroundColor)
                    }
                }

                if showHUD && target.files.count > 1 {
                    mangaBottomScrubber
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("\(target.title) (\(min(currentIndex + 1, max(target.files.count, 1)))/\(target.files.count))")
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

                    if target.files.indices.contains(currentIndex) {
                        ShareLink(item: target.files[currentIndex].fileURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
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
        let count = target.files.count
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

private struct ReaderPageImage: View {
    let url: URL

    var body: some View {
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
    }
}

private struct ZoomableImagePage: View {
    let url: URL
    var onSingleTap: () -> Void = {}
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                ReaderPageImage(url: url)
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
                        Text("No manga chapters or image folders yet. Import a folder of images, extract a .cbz/.zip archive, or use \"Read Page as Manga\" in the Browser tab.")
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
            .applyAppTheme()
            .navigationTitle("Manga & Story Reader")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
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
}
