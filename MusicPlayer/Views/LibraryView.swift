import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum MediaFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case songs = "Songs"
    case videos = "Videos"
    case files = "Files"
    case favorites = "Favorites"
    case recents = "Recents"

    var id: String { rawValue }
}

enum MediaSortOrder: String, CaseIterable, Identifiable {
    case newest = "Newest"
    case name = "Name"
    case size = "Largest"
    case duration = "Duration"

    var id: String { rawValue }
}

private enum RenameTarget: Identifiable {
    case media(MediaItem)
    case file(LocalFile)
    case folder(LocalFolder)

    var id: UUID {
        switch self {
        case .media(let item): return item.id
        case .file(let file): return file.id
        case .folder(let folder): return folder.id
        }
    }

    var currentName: String {
        switch self {
        case .media(let item): return item.name
        case .file(let file): return file.name
        case .folder(let folder): return folder.name
        }
    }

    var label: String {
        switch self {
        case .media(let item): return item.fileName
        case .file(let file): return file.fileName
        case .folder(let folder): return folder.name
        }
    }
}

private struct MoveTarget: Identifiable {
    let id = UUID()
    let mediaItems: [MediaItem]
    let otherFiles: [LocalFile]
}

struct LibraryView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(WiFiTransferServer.self) private var wifiServer
    @Environment(WebMediaDownloader.self) private var downloader
    @Binding var showPlayerSheet: Bool
    @Binding var quickLookTarget: QuickLookTarget?

    @State private var filter: MediaFilter = .all
    @State private var sortOrder: MediaSortOrder = .newest
    @State private var searchText = ""
    @State private var currentFolderPath = ""

    @State private var showFileImporter = false
    @State private var showPhotosPicker = false
    @State private var showWiFiSheet = false
    @State private var showEqualizerSheet = false
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var selectedPhotoItems: [PhotosPickerItem] = []

    @State private var renameTarget: RenameTarget?
    @State private var renameText = ""
    @State private var folderToDelete: LocalFolder?
    @State private var editingInfoItem: MediaItem?
    @State private var moveTarget: MoveTarget?

    @State private var isSelecting = false
    @State private var selectedMediaPaths: Set<String> = []
    @State private var selectedOtherPaths: Set<String> = []
    @State private var showBatchPlaylistSheet = false

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsFolderHierarchy: Bool {
        (filter == .all || filter == .files) && trimmedSearch.isEmpty
    }

    private var visibleFolders: [LocalFolder] {
        guard showsFolderHierarchy else { return [] }
        return mediaManager.folders
            .filter { $0.parentRelativePath == currentFolderPath }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var filteredMediaItems: [MediaItem] {
        guard filter != .files else { return [] }

        let sourceItems: [MediaItem]
        switch filter {
        case .favorites:
            sourceItems = mediaManager.favoriteItems
        case .recents:
            sourceItems = mediaManager.recentItems
        case .songs:
            sourceItems = mediaManager.items.filter { !$0.isVideo }
        case .videos:
            sourceItems = mediaManager.items.filter { $0.isVideo }
        case .all:
            if trimmedSearch.isEmpty {
                sourceItems = mediaManager.items.filter { $0.folderRelativePath == currentFolderPath }
            } else {
                sourceItems = mediaManager.items
            }
        case .files:
            sourceItems = []
        }

        let matched = sourceItems.filter { item in
            trimmedSearch.isEmpty ||
                item.displayTitle.localizedCaseInsensitiveContains(trimmedSearch) ||
                item.name.localizedCaseInsensitiveContains(trimmedSearch) ||
                (item.artist?.localizedCaseInsensitiveContains(trimmedSearch) ?? false) ||
                item.fileExtension.localizedCaseInsensitiveContains(trimmedSearch)
        }

        if filter == .recents && trimmedSearch.isEmpty && sortOrder == .newest {
            return matched
        }

        switch sortOrder {
        case .newest:
            return matched.sorted { $0.dateAdded > $1.dateAdded }
        case .name:
            return matched.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        case .size:
            return matched.sorted { $0.fileSize > $1.fileSize }
        case .duration:
            return matched.sorted { ($0.durationSeconds ?? 0) > ($1.durationSeconds ?? 0) }
        }
    }

    private var filteredOtherFiles: [LocalFile] {
        guard filter == .all || filter == .files else { return [] }

        let base = mediaManager.otherFiles.filter { file in
            let matchesFolder = !trimmedSearch.isEmpty || file.folderRelativePath == currentFolderPath
            let matchesSearch = trimmedSearch.isEmpty ||
                file.name.localizedCaseInsensitiveContains(trimmedSearch) ||
                file.fileExtension.localizedCaseInsensitiveContains(trimmedSearch)
            return matchesFolder && matchesSearch
        }

        switch sortOrder {
        case .newest:
            return base.sorted { $0.dateAdded > $1.dateAdded }
        case .name:
            return base.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size, .duration:
            return base.sorted { $0.fileSize > $1.fileSize }
        }
    }

    private var hasAnyStoredItems: Bool {
        !mediaManager.items.isEmpty || !mediaManager.otherFiles.isEmpty || !mediaManager.folders.isEmpty
    }

    private var breadcrumbSegments: [(label: String, path: String)] {
        guard !currentFolderPath.isEmpty else { return [] }
        let parts = currentFolderPath.split(separator: "/").map(String.init)
        var result: [(String, String)] = [("Root", "")]
        var running = ""
        for part in parts {
            running = running.isEmpty ? part : "\(running)/\(part)"
            result.append((part, running))
        }
        return result
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !downloader.activeDownloads.isEmpty {
                    activeDownloadsBanner
                }

                if hasAnyStoredItems {
                    filterStrip
                }

                if showsFolderHierarchy && !currentFolderPath.isEmpty {
                    breadcrumbBar
                }

                Group {
                    if !hasAnyStoredItems {
                        emptyLibraryView
                    } else if visibleFolders.isEmpty && filteredMediaItems.isEmpty && filteredOtherFiles.isEmpty {
                        if !trimmedSearch.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                        } else {
                            ContentUnavailableView(
                                currentFolderPath.isEmpty ? "Nothing in \(filter.rawValue)" : "Folder is Empty",
                                systemImage: filter == .files ? "doc" : (currentFolderPath.isEmpty ? "music.note" : "folder"),
                                description: Text("Import files, create a subfolder, or move media here.")
                            )
                        }
                    } else {
                        List {
                            if !visibleFolders.isEmpty {
                                Section("Folders") {
                                    ForEach(visibleFolders) { folder in
                                        folderRow(folder)
                                    }
                                }
                            }

                            if !filteredMediaItems.isEmpty {
                                Section {
                                    ForEach(filteredMediaItems) { item in
                                        mediaRowItem(item)
                                    }
                                } header: {
                                    if !visibleFolders.isEmpty || !filteredOtherFiles.isEmpty {
                                        Text("Media")
                                    }
                                }
                            }

                            if !filteredOtherFiles.isEmpty {
                                Section {
                                    ForEach(filteredOtherFiles) { file in
                                        otherFileRowItem(file)
                                    }
                                } header: {
                                    if !visibleFolders.isEmpty || !filteredMediaItems.isEmpty {
                                        Text("Documents & Files")
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .refreshable {
                            mediaManager.loadLocalFiles()
                        }
                    }
                }

                if isSelecting {
                    batchSelectionBar
                }
            }
            .navigationTitle(currentFolderPath.isEmpty ? "Music Player" : (currentFolderPath as NSString).lastPathComponent)
            .searchable(text: $searchText, prompt: "Search songs, videos, files")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 12) {
                        if !currentFolderPath.isEmpty && showsFolderHierarchy {
                            Button {
                                currentFolderPath = parentPath(of: currentFolderPath)
                            } label: {
                                Image(systemName: "chevron.backward")
                            }
                        }

                        Menu {
                            Picker("Sort By", selection: $sortOrder) {
                                ForEach(MediaSortOrder.allCases) { order in
                                    Text(order.rawValue).tag(order)
                                }
                            }
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down.circle")
                        }
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if hasAnyStoredItems {
                        Button(isSelecting ? "Done" : "Select") {
                            isSelecting.toggle()
                            if !isSelecting {
                                selectedMediaPaths.removeAll()
                                selectedOtherPaths.removeAll()
                            }
                        }
                    }

                    Button {
                        showWiFiSheet = true
                    } label: {
                        Image(systemName: wifiServer.isRunning ? "wifi.circle.fill" : "wifi")
                            .foregroundStyle(wifiServer.isRunning ? .green : .accentColor)
                    }

                    Menu {
                        Button {
                            newFolderName = ""
                            showNewFolderAlert = true
                        } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }

                        Button {
                            showFileImporter = true
                        } label: {
                            Label("Import from Files", systemImage: "doc.badge.plus")
                        }

                        Button {
                            showPhotosPicker = true
                        } label: {
                            Label("Import Video from Photos", systemImage: "photo.on.rectangle.angled")
                        }

                        Button {
                            showWiFiSheet = true
                        } label: {
                            Label("Wi-Fi Transfer", systemImage: "antenna.radiowaves.left.and.right")
                        }

                        Button {
                            showEqualizerSheet = true
                        } label: {
                            Label("Audio Equalizer", systemImage: "slider.vertical.3")
                        }

                        Divider()

                        Button {
                            mediaManager.loadLocalFiles()
                        } label: {
                            Label("Refresh Library", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
            }
            .sheet(isPresented: $showWiFiSheet) {
                WiFiTransferView()
            }
            .sheet(isPresented: $showEqualizerSheet) {
                EqualizerView()
            }
            .sheet(item: $editingInfoItem) { item in
                EditTrackInfoSheet(item: item)
            }
            .sheet(item: $moveTarget) { target in
                MoveToFolderSheet(
                    target: target,
                    onComplete: {
                        isSelecting = false
                        selectedMediaPaths.removeAll()
                        selectedOtherPaths.removeAll()
                    }
                )
            }
            .sheet(isPresented: $showBatchPlaylistSheet) {
                BatchAddToPlaylistSheet(
                    items: mediaManager.items.filter { selectedMediaPaths.contains($0.relativePath) },
                    onDone: {
                        isSelecting = false
                        selectedMediaPaths.removeAll()
                        selectedOtherPaths.removeAll()
                    }
                )
            }
            .miniPlayerInset(showPlayerSheet: $showPlayerSheet)
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    let folder = showsFolderHierarchy ? currentFolderPath : ""
                    for url in urls {
                        mediaManager.importAnyFile(from: url, inFolder: folder)
                    }
                case .failure(let error):
                    mediaManager.errorMessage = "File picker failed: \(error.localizedDescription)"
                }
            }
            .photosPicker(
                isPresented: $showPhotosPicker,
                selection: $selectedPhotoItems,
                maxSelectionCount: 5,
                matching: .videos
            )
            .onChange(of: selectedPhotoItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                let picked = newItems
                let targetFolder = showsFolderHierarchy ? currentFolderPath : ""
                selectedPhotoItems = []
                Task {
                    for pickedItem in picked {
                        do {
                            if let movie = try await pickedItem.loadTransferable(type: MovieTransferable.self) {
                                await MainActor.run {
                                    mediaManager.importTemporaryFile(
                                        from: movie.url,
                                        preferredFileName: movie.suggestedFileName,
                                        inFolder: targetFolder
                                    )
                                }
                            }
                        } catch {
                            await MainActor.run {
                                mediaManager.errorMessage = "Could not import video: \(error.localizedDescription)"
                            }
                        }
                    }
                }
            }
            .alert("New Folder", isPresented: $showNewFolderAlert) {
                TextField("Folder name", text: $newFolderName)
                Button("Cancel", role: .cancel) { newFolderName = "" }
                Button("Create") {
                    let parent = showsFolderHierarchy ? currentFolderPath : ""
                    mediaManager.createFolder(named: newFolderName, inParentFolder: parent)
                    newFolderName = ""
                }
            } message: {
                Text("Enter a name for the new folder.")
            }
            .alert(
                "Rename",
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                )
            ) {
                TextField("New name", text: $renameText)
                Button("Cancel", role: .cancel) {
                    renameTarget = nil
                }
                Button("Save") {
                    if let renameTarget {
                        switch renameTarget {
                        case .media(let item):
                            mediaManager.rename(item, to: renameText)
                        case .file(let file):
                            mediaManager.renameOtherFile(file, to: renameText)
                        case .folder(let folder):
                            if currentFolderPath == folder.relativePath {
                                currentFolderPath = ""
                            }
                            mediaManager.renameFolder(folder, to: renameText)
                        }
                    }
                    renameTarget = nil
                }
            } message: {
                if let renameTarget {
                    Text("Enter a new name for \"\(renameTarget.label)\".")
                }
            }
            .confirmationDialog(
                "Delete Folder \"\(folderToDelete?.name ?? "")\"?",
                isPresented: Binding(
                    get: { folderToDelete != nil },
                    set: { if !$0 { folderToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let folder = folderToDelete {
                    Button("Delete Folder & Contents", role: .destructive) {
                        if currentFolderPath == folder.relativePath || currentFolderPath.hasPrefix("\(folder.relativePath)/") {
                            currentFolderPath = folder.parentRelativePath
                        }
                        mediaManager.deleteFolder(folder)
                        folderToDelete = nil
                    }
                }
                Button("Cancel", role: .cancel) { folderToDelete = nil }
            } message: {
                Text("All files inside this folder will be permanently deleted.")
            }
        }
    }

    private var activeDownloadsBanner: some View {
        VStack(spacing: 6) {
            ForEach(downloader.activeDownloads) { dl in
                HStack(spacing: 10) {
                    ProgressView(value: dl.progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                    Text("\(dl.title) (\(Int(dl.progress * 100))%)")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Button {
                        downloader.cancelDownload(id: dl.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12))
    }

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MediaFilter.allCases) { option in
                    let isSelected = filter == option
                    Button {
                        filter = option
                    } label: {
                        Text(option.rawValue)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
                            )
                            .foregroundStyle(isSelected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(breadcrumbSegments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        currentFolderPath = segment.path
                    } label: {
                        Text(segment.label)
                            .font(.caption.weight(index == breadcrumbSegments.count - 1 ? .bold : .medium))
                            .foregroundStyle(index == breadcrumbSegments.count - 1 ? Color.primary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    private func folderRow(_ folder: LocalFolder) -> some View {
        HStack(spacing: 14) {
            Button {
                currentFolderPath = folder.relativePath
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.blue.opacity(0.16))
                            .frame(width: 54, height: 54)
                        Image(systemName: "folder.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.blue)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(folder.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("\(folder.itemCount) \(folder.itemCount == 1 ? "item" : "items")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                renameText = folder.name
                renameTarget = .folder(folder)
            } label: {
                Label("Rename Folder", systemImage: "pencil")
            }

            Button(role: .destructive) {
                folderToDelete = folder
            } label: {
                Label("Delete Folder", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                folderToDelete = folder
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func mediaRowItem(_ item: MediaItem) -> some View {
        HStack(spacing: 10) {
            if isSelecting {
                let checked = selectedMediaPaths.contains(item.relativePath)
                Button {
                    if checked {
                        selectedMediaPaths.remove(item.relativePath)
                    } else {
                        selectedMediaPaths.insert(item.relativePath)
                    }
                } label: {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(checked ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }

            MediaRowView(
                item: item,
                onPlay: {
                    if isSelecting {
                        if selectedMediaPaths.contains(item.relativePath) {
                            selectedMediaPaths.remove(item.relativePath)
                        } else {
                            selectedMediaPaths.insert(item.relativePath)
                        }
                        return
                    }
                    if mediaManager.currentItem?.relativePath == item.relativePath {
                        if item.isVideo {
                            showPlayerSheet = true
                            if !mediaManager.isPlaying {
                                mediaManager.resume()
                            }
                        } else {
                            mediaManager.togglePlayPause()
                        }
                    } else {
                        mediaManager.play(item)
                        if item.isVideo {
                            showPlayerSheet = true
                        }
                    }
                },
                onQuickLook: {
                    quickLookTarget = QuickLookTarget(title: item.displayTitle, fileURL: item.fileURL)
                },
                onRename: {
                    renameText = item.name
                    renameTarget = .media(item)
                },
                onEditInfo: {
                    editingInfoItem = item
                },
                onMove: {
                    moveTarget = MoveTarget(mediaItems: [item], otherFiles: [])
                }
            )
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !item.isHLS {
                Button {
                    Task {
                        await mediaManager.convertToMP4(item: item)
                    }
                } label: {
                    Label("MP4", systemImage: "film.stack")
                }
                .tint(.indigo)
                .disabled(mediaManager.convertingItemID != nil)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                mediaManager.delete(item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func otherFileRowItem(_ file: LocalFile) -> some View {
        HStack(spacing: 10) {
            if isSelecting {
                let checked = selectedOtherPaths.contains(file.relativePath)
                Button {
                    if checked {
                        selectedOtherPaths.remove(file.relativePath)
                    } else {
                        selectedOtherPaths.insert(file.relativePath)
                    }
                } label: {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(checked ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }

            LocalFileRowView(
                file: file,
                onPreview: {
                    if isSelecting {
                        if selectedOtherPaths.contains(file.relativePath) {
                            selectedOtherPaths.remove(file.relativePath)
                        } else {
                            selectedOtherPaths.insert(file.relativePath)
                        }
                        return
                    }
                    quickLookTarget = QuickLookTarget(title: file.name, fileURL: file.fileURL)
                },
                onRename: {
                    renameText = file.name
                    renameTarget = .file(file)
                },
                onMove: {
                    moveTarget = MoveTarget(mediaItems: [], otherFiles: [file])
                }
            )
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                mediaManager.deleteOtherFile(file)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var batchSelectionBar: some View {
        let totalSelected = selectedMediaPaths.count + selectedOtherPaths.count
        let allSelected = selectedMediaPaths.count == filteredMediaItems.count &&
            selectedOtherPaths.count == filteredOtherFiles.count &&
            totalSelected > 0

        return HStack(spacing: 12) {
            Button(allSelected ? "Deselect" : "Select All") {
                if allSelected {
                    selectedMediaPaths.removeAll()
                    selectedOtherPaths.removeAll()
                } else {
                    selectedMediaPaths = Set(filteredMediaItems.map(\.relativePath))
                    selectedOtherPaths = Set(filteredOtherFiles.map(\.relativePath))
                }
            }
            .font(.subheadline.weight(.medium))

            Spacer()

            Button {
                let items = mediaManager.items.filter { selectedMediaPaths.contains($0.relativePath) }
                let files = mediaManager.otherFiles.filter { selectedOtherPaths.contains($0.relativePath) }
                moveTarget = MoveTarget(mediaItems: items, otherFiles: files)
            } label: {
                Label("Move", systemImage: "folder")
                    .font(.subheadline.weight(.medium))
            }
            .disabled(totalSelected == 0)

            Button {
                showBatchPlaylistSheet = true
            } label: {
                Label("Playlist", systemImage: "text.badge.plus")
                    .font(.subheadline.weight(.medium))
            }
            .disabled(selectedMediaPaths.isEmpty)

            Button(role: .destructive) {
                for item in mediaManager.items where selectedMediaPaths.contains(item.relativePath) {
                    mediaManager.delete(item)
                }
                for file in mediaManager.otherFiles where selectedOtherPaths.contains(file.relativePath) {
                    mediaManager.deleteOtherFile(file)
                }
                selectedMediaPaths.removeAll()
                selectedOtherPaths.removeAll()
                isSelecting = false
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.subheadline.weight(.medium))
            }
            .disabled(totalSelected == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func parentPath(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }

    private var emptyLibraryView: some View {
        ContentUnavailableView {
            Label("No Local Files Yet", systemImage: "play.square.stack")
        } description: {
            Text("Import songs, videos, or documents from Files, Photos, Wi-Fi Transfer, or the built-in ad-free Browser.")
        } actions: {
            HStack(spacing: 12) {
                Button {
                    showFileImporter = true
                } label: {
                    Label("Import Files", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showPhotosPicker = true
                } label: {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

private struct MoveToFolderSheet: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(\.dismiss) private var dismiss

    let target: MoveTarget
    let onComplete: () -> Void

    @State private var showCreateFolder = false
    @State private var newFolderName = ""

    var body: some View {
        NavigationStack {
            List {
                Button {
                    moveAll(to: "")
                } label: {
                    Label("Root (Library)", systemImage: "house")
                }

                if !mediaManager.folders.isEmpty {
                    Section("Folders") {
                        ForEach(mediaManager.folders) { folder in
                            Button {
                                moveAll(to: folder.relativePath)
                            } label: {
                                HStack {
                                    Label(folder.relativePath, systemImage: "folder.fill")
                                    Spacer()
                                    Text("\(folder.itemCount)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Move to Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newFolderName = ""
                        showCreateFolder = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
            .alert("New Folder", isPresented: $showCreateFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Cancel", role: .cancel) { newFolderName = "" }
                Button("Create & Move") {
                    if let folder = mediaManager.createFolder(named: newFolderName) {
                        moveAll(to: folder.relativePath)
                    }
                    newFolderName = ""
                }
            }
        }
    }

    private func moveAll(to destinationFolder: String) {
        for item in target.mediaItems {
            mediaManager.moveItem(item, toFolder: destinationFolder)
        }
        for file in target.otherFiles {
            mediaManager.moveOtherFile(file, toFolder: destinationFolder)
        }
        onComplete()
        dismiss()
    }
}

private struct BatchAddToPlaylistSheet: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(\.dismiss) private var dismiss

    let items: [MediaItem]
    let onDone: () -> Void

    @State private var showNewPlaylist = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                if mediaManager.playlists.isEmpty {
                    Text("No playlists yet. Tap + to create one.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mediaManager.playlists) { playlist in
                        Button {
                            for item in items {
                                mediaManager.add(item, to: playlist)
                            }
                            onDone()
                            dismiss()
                        } label: {
                            Label(playlist.name, systemImage: "music.note.list")
                        }
                    }
                }
            }
            .navigationTitle("Add \(items.count) to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newName = ""
                        showNewPlaylist = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("New Playlist", isPresented: $showNewPlaylist) {
                TextField("Playlist name", text: $newName)
                Button("Cancel", role: .cancel) { newName = "" }
                Button("Create & Add") {
                    if let playlist = mediaManager.createPlaylist(name: newName, initialPaths: items.map(\.relativePath)) {
                        mediaManager.statusMessage = "Added \(items.count) to \"\(playlist.name)\""
                        onDone()
                        dismiss()
                    }
                    newName = ""
                }
            }
        }
    }
}
