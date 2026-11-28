import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

private struct AppIconChoice: Identifiable {
    let id: String
    let title: String
    let iconName: String
    let previewColor: Color

    static let all: [AppIconChoice] = [
        AppIconChoice(id: "default", title: "Default", iconName: "", previewColor: .indigo),
        AppIconChoice(id: "dark", title: "Dark", iconName: "AppIcon-Dark", previewColor: Color(white: 0.15)),
        AppIconChoice(id: "light", title: "Light", iconName: "AppIcon-Light", previewColor: Color(red: 0.2, green: 0.45, blue: 0.9)),
        AppIconChoice(id: "midnight", title: "Midnight", iconName: "AppIcon-Midnight", previewColor: Color(red: 0.12, green: 0.22, blue: 0.55)),
        AppIconChoice(id: "amber", title: "Amber", iconName: "AppIcon-Amber", previewColor: .orange)
    ]
}

struct SettingsView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(AppSettings.self) private var settings
    @Environment(BrowserStore.self) private var browserStore
    @Environment(WiFiTransferServer.self) private var wifiServer
    @Binding var showPlayerSheet: Bool

    @State private var showWiFiSheet = false
    @State private var showBackupSheet = false
    @State private var showEqualizerSheet = false
    @State private var showMangaReaderSheet = false
    @State private var showWrappedSheet = false
    @State private var showClearedAlert = false
    @State private var iconErrorMessage: String?

    @State private var selectedBackgroundPhoto: PhotosPickerItem?
    @State private var showBackgroundFileImporter = false

    private let durationOptions = [0, 10, 30, 60, 120]

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section("Appearance & Custom Theme") {
                    Picker("Theme", selection: $settings.appearanceMode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    NavigationLink {
                        AppIconsPickerView(iconErrorMessage: $iconErrorMessage)
                    } label: {
                        HStack(spacing: 12) {
                            if settings.useCustomAppIcon, let customIcon = settings.customAppIconImage {
                                Image(uiImage: customIcon)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 28, height: 28)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            } else {
                                Image(systemName: "app.badge")
                                    .foregroundStyle(Color.accentColor)
                            }
                            Text("App Icon")
                            Spacer()
                            Text(currentIconLabel)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            if let bgImage = settings.customBackgroundImage {
                                Image(uiImage: bgImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            } else {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.15))
                                    .frame(width: 48, height: 48)
                                    .overlay {
                                        Image(systemName: "photo.on.rectangle")
                                            .foregroundStyle(Color.accentColor)
                                    }
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("App Background Picture")
                                    .font(.subheadline.weight(.semibold))
                                Text(settings.customBackgroundImage != nil ? "Custom background active" : "Upload a photo for the app background")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack(spacing: 10) {
                            PhotosPicker(selection: $selectedBackgroundPhoto, matching: .images) {
                                Label("Photos", systemImage: "photo")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                showBackgroundFileImporter = true
                            } label: {
                                Label("Files", systemImage: "folder")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            if settings.customBackgroundImage != nil {
                                Button(role: .destructive) {
                                    settings.clearCustomBackgroundImage()
                                    mediaManager.statusMessage = "Removed background picture"
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    if settings.customBackgroundImage != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Background Dimming")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(Int(settings.backgroundDimOpacity * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $settings.backgroundDimOpacity, in: 0.0...0.85, step: 0.05)
                        }

                        Toggle("Blur Background Picture", isOn: $settings.backgroundBlurEnabled)
                    }

                    Toggle("Custom Background Color", isOn: $settings.useCustomBackgroundColor)

                    if settings.useCustomBackgroundColor {
                        ColorPicker(
                            "App Background Color",
                            selection: Binding(
                                get: { settings.customBackgroundColor },
                                set: { settings.customBackgroundColor = $0 }
                            ),
                            supportsOpacity: false
                        )
                    }

                    Toggle("Custom Letters / Text Color", isOn: $settings.useCustomTextColor)

                    if settings.useCustomTextColor {
                        ColorPicker(
                            "Letters & Text Color",
                            selection: Binding(
                                get: { settings.customTextColor },
                                set: { settings.customTextColor = $0 }
                            ),
                            supportsOpacity: false
                        )
                    }

                    if settings.hasCustomBackground || settings.hasCustomTextColor {
                        Button(role: .destructive) {
                            settings.resetCustomTheme()
                            mediaManager.statusMessage = "Reset background & text colors to default"
                        } label: {
                            Label("Reset Background & Text Colors", systemImage: "arrow.counterclockwise")
                        }
                    }
                }

                Section("Player & Tools") {
                    Toggle("Quick access to Last Playlist", isOn: $settings.quickAccessLastPlaylist)

                    Toggle(isOn: $settings.keepImportingWhenLocked) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Background Sync & Analysis Keep-Alive")
                            Text("Plays silence while downloads, caching, or song analysis run in the background and nothing else is playing, so iOS doesn't pause them. Never interrupts your music.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: settings.keepImportingWhenLocked) { _, enabled in
                        if !enabled {
                            ImportKeepAlive.shared.stop()
                        } else {
                            BackgroundWorkCoordinator.shared.refreshBackgroundState()
                        }
                    }

                    Toggle(isOn: $settings.autoIdentifyImportedSongs) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-Identify Imported Songs")
                            Text("Fixes each imported song's title, artist, album and cover art so lyrics match. Uses the playlist, YouTube's Music info and music catalogs; only renames when two sources agree")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let reason = SongIdentificationService.shared.engineUnavailableReason {
                                Text(reason)
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    Toggle(isOn: $settings.autoAISyncLyrics) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-Sync & Recognize Lyrics")
                            Text("Automatically identifies and aligns mismatched lyrics while playing")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $settings.crossfadeEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Fade Between Songs (Crossfade)")
                            Text(settings.crossfadeEnabled
                                 ? String(format: "Smoothly blends songs over %.1fs", settings.crossfadeDurationSeconds)
                                 : "Seamless transition between audio tracks")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if settings.crossfadeEnabled {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Fade Duration")
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "%.1f sec", settings.crossfadeDurationSeconds))
                                    .font(.subheadline.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            Slider(value: $settings.crossfadeDurationSeconds, in: 1...12, step: 0.5)
                            HStack {
                                Text("1s")
                                Spacer()
                                Text("6s")
                                Spacer()
                                Text("12s")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }

                    Button {
                        showEqualizerSheet = true
                    } label: {
                        Label("5-Band Audio Equalizer", systemImage: "slider.vertical.3")
                    }

                    Button {
                        showWrappedSheet = true
                    } label: {
                        Label("Listening Wrapped & Dec 1st Reveal", systemImage: "sparkles")
                    }

                    Button {
                        showWiFiSheet = true
                    } label: {
                        HStack {
                            Label("Wi-Fi Transfer", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            if wifiServer.isRunning {
                                Text("Running")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.green)
                            }
                        }
                    }

                    Button {
                        showBackupSheet = true
                    } label: {
                        HStack {
                            Label("Backup & Restore All Songs/Videos", systemImage: "externaldrive.badge.icloud")
                            Spacer()
                            if let last = LibraryBackupService.shared.lastBackupDate {
                                Text(last, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Video Setting") {
                    Toggle(
                        "Ask before caching",
                        isOn: Binding(
                            get: { settings.askBeforeCaching },
                            set: { settings.setAskBeforeCaching($0) }
                        )
                    )

                    Toggle(
                        "Enable Automatic Caching",
                        isOn: Binding(
                            get: { settings.autoCacheDetectedMedia },
                            set: { settings.setAutoCacheDetectedMedia($0) }
                        )
                    )

                    Toggle("Open Player After Caching", isOn: $settings.autoOpenPlayerAfterCache)

                    Toggle("Save Cached Media to Playlist", isOn: $settings.autoAddDownloadsToPlaylist)

                    if settings.autoAddDownloadsToPlaylist {
                        Picker("Download Playlist", selection: $settings.targetDownloadPlaylistIDString) {
                            Text("Auto (\"Last Played\")").tag("")
                            ForEach(mediaManager.playlists) { playlist in
                                Text(playlist.name).tag(playlist.id.uuidString)
                            }
                        }
                    }

                    Picker("Only cache videos with duration less than", selection: $settings.maxCacheDurationMinutes) {
                        Text("No Limit").tag(0)
                        ForEach(durationOptions.filter { $0 > 0 }, id: \.self) { mins in
                            Text("\(mins) min").tag(mins)
                        }
                    }

                    Toggle("Inline video player", isOn: $settings.inlineVideoPlayback)
                    Toggle("Web page dark mode", isOn: $settings.webDarkModeEnabled)
                    Toggle("Ad-Block", isOn: $settings.adBlockEnabled)

                    if !settings.suppressedCacheHosts.isEmpty {
                        Button("Reset \"Don't Remind\" Sites (\(settings.suppressedCacheHosts.count))") {
                            settings.clearSuppressedCacheHosts()
                            mediaManager.statusMessage = "Cleared muted prompt sites"
                        }
                    }
                }

                Section("Browser & Reader") {
                    Button {
                        showMangaReaderSheet = true
                    } label: {
                        Label("Open Manga & Story Reader", systemImage: "book.pages")
                    }

                    Picker("Search Engine", selection: $settings.searchEngine) {
                        ForEach(SearchEngineOption.allCases) { engine in
                            Text(engine.rawValue).tag(engine)
                        }
                    }

                    Picker("Reading Direction", selection: $settings.readingDirection) {
                        ForEach(ReadingDirection.allCases) { dir in
                            Text(dir.displayTitle).tag(dir)
                        }
                    }
                }

                Section("System & Privacy") {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Language", systemImage: "globe")
                    }

                    Button(role: .destructive) {
                        LocalMediaCacheProxy.shared.clearCache()
                        URLCache.shared.removeAllCachedResponses()
                        MediaInterceptURLProtocol.sharedCache.removeAllCachedResponses()
                        mediaManager.statusMessage = "Cleared media stream cache"
                    } label: {
                        HStack {
                            Label("Clear Stream Cache", systemImage: "internaldrive")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: LocalMediaCacheProxy.shared.cachedBytes, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button(role: .destructive) {
                        browserStore.clearHistory()
                        let dataStore = WKWebsiteDataStore.default()
                        dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {}
                        }
                        showClearedAlert = true
                    } label: {
                        Label("Clear History", systemImage: "trash")
                    }
                }

                Section("Storage & About") {
                    LabeledContent("Stored Media", value: "\(mediaManager.items.count) items")
                    LabeledContent("Documents & Files", value: "\(mediaManager.otherFiles.count) files")
                    LabeledContent("Folders", value: "\(mediaManager.folders.count)")
                    LabeledContent("Total Size", value: mediaManager.formattedTotalStorage)
                    LabeledContent("Ads & Tracking", value: "None (100% Ad-Free)")

                    Button {
                        exportSyncDiagnostics()
                    } label: {
                        HStack {
                            Label("Export Sync & Song ID Diagnostics", systemImage: "square.and.arrow.up")
                            Spacer()
                            Text("\(SyncDiagnosticsService.shared.recordCount()) tracks")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button(role: .destructive) {
                        SyncDiagnosticsService.shared.clearAll()
                        mediaManager.statusMessage = "Cleared sync diagnostics log"
                    } label: {
                        Label("Clear Diagnostics Log", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Setting")
            .onAppear {
                syncTargetDownloadPlaylist()
            }
            .onChange(of: mediaManager.playlists) { _, _ in
                syncTargetDownloadPlaylist()
            }
            .onChange(of: selectedBackgroundPhoto) { _, newItem in
                guard let newItem else { return }
                selectedBackgroundPhoto = nil
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            settings.saveCustomBackgroundImage(image)
                            mediaManager.statusMessage = "Updated app background picture"
                        }
                    }
                }
            }
            .fileImporter(
                isPresented: $showBackgroundFileImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if didAccess { url.stopAccessingSecurityScopedResource() }
                    }
                    if let data = try? Data(contentsOf: url),
                       let image = UIImage(data: data) {
                        settings.saveCustomBackgroundImage(image)
                        mediaManager.statusMessage = "Updated app background picture"
                    } else {
                        mediaManager.errorMessage = "Could not load selected image file."
                    }
                }
            }
            .miniPlayerInset(showPlayerSheet: $showPlayerSheet)
            .sheet(isPresented: $showWiFiSheet) {
                WiFiTransferView()
            }
            .sheet(isPresented: $showBackupSheet) {
                LibraryBackupSheet()
            }
            .sheet(isPresented: $showEqualizerSheet) {
                EqualizerView()
            }
            .sheet(isPresented: $showMangaReaderSheet) {
                MangaLibrarySheetView()
            }
            .sheet(isPresented: $showWrappedSheet) {
                WrappedDashboardSheet()
            }
            .alert("History Cleared", isPresented: $showClearedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Browsing history, cookies, and website caches have been removed.")
            }
            .alert(
                "App Icon Notice",
                isPresented: Binding(
                    get: { iconErrorMessage != nil },
                    set: { if !$0 { iconErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { iconErrorMessage = nil }
            } message: {
                Text(iconErrorMessage ?? "")
            }
        }
    }

    private var currentIconLabel: String {
        if settings.useCustomAppIcon && settings.customAppIconImage != nil {
            return "Custom Picture"
        }
        return AppIconChoice.all.first(where: { $0.iconName == settings.selectedAppIconName })?.title ?? "Default"
    }

    private func exportSyncDiagnostics() {
        guard let url = SyncDiagnosticsService.shared.exportDiagnosticsFileURL() else {
            mediaManager.errorMessage = "Could not export diagnostics log."
            return
        }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? scene.windows.first?.rootViewController else {
            return
        }
        var presenter = root
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        if let pop = activity.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        }
        presenter.present(activity, animated: true)
    }

    private func syncTargetDownloadPlaylist() {
        guard !settings.targetDownloadPlaylistIDString.isEmpty else { return }
        if !mediaManager.playlists.contains(where: { $0.id.uuidString == settings.targetDownloadPlaylistIDString }) {
            settings.targetDownloadPlaylistIDString = ""
        }
    }
}

private struct AppIconsPickerView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MediaManager.self) private var mediaManager
    @Binding var iconErrorMessage: String?

    @State private var selectedIconPhoto: PhotosPickerItem?
    @State private var showIconFileImporter = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        if let customIcon = settings.customAppIconImage {
                            Image(uiImage: customIcon)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(Color.accentColor.opacity(0.16))
                                .frame(width: 56, height: 56)
                                .overlay {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.title3)
                                        .foregroundStyle(Color.accentColor)
                                }
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Custom App Icon Picture")
                                .font(.body.weight(.semibold))
                            Text(
                                settings.customAppIconImage != nil
                                    ? "Used for in-app branding & default player artwork"
                                    : "Upload any picture from Photos or Files"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if settings.useCustomAppIcon && settings.customAppIconImage != nil {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    HStack(spacing: 10) {
                        PhotosPicker(selection: $selectedIconPhoto, matching: .images) {
                            Label("Upload Photo", systemImage: "photo")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            showIconFileImporter = true
                        } label: {
                            Label("From Files", systemImage: "folder")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    if settings.customAppIconImage != nil {
                        HStack(spacing: 10) {
                            if !settings.useCustomAppIcon {
                                Button {
                                    settings.useCustomAppIcon = true
                                } label: {
                                    Label("Use Custom Picture", systemImage: "checkmark.circle")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                            }

                            Button(role: .destructive) {
                                settings.clearCustomAppIcon()
                                mediaManager.statusMessage = "Removed custom app icon picture"
                            } label: {
                                Label("Remove Custom Picture", systemImage: "trash")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Custom Uploaded Picture")
            } footer: {
                Text("Your custom uploaded picture is displayed across the app and as default player artwork. You can also select one of the built-in iOS Home Screen icons below.")
            }

            Section("Home Screen Icons") {
                ForEach(AppIconChoice.all) { choice in
                    let isSelected = !settings.useCustomAppIcon && settings.selectedAppIconName == choice.iconName
                    Button {
                        applyIcon(choice)
                    } label: {
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(choice.previewColor.gradient)
                                .frame(width: 48, height: 48)
                                .overlay {
                                    Image(systemName: "play.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.white)
                                }

                            Text(choice.title)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)

                            Spacer()

                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .applyAppTheme()
        .navigationTitle("App Icons")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedIconPhoto) { _, newItem in
            guard let newItem else { return }
            selectedIconPhoto = nil
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await MainActor.run {
                        settings.saveCustomAppIcon(image)
                        mediaManager.statusMessage = "Saved custom app icon picture"
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showIconFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                }
                if let data = try? Data(contentsOf: url),
                   let image = UIImage(data: data) {
                    settings.saveCustomAppIcon(image)
                    mediaManager.statusMessage = "Saved custom app icon picture"
                } else {
                    iconErrorMessage = "Could not load the selected image file."
                }
            }
        }
    }

    private func applyIcon(_ choice: AppIconChoice) {
        settings.useCustomAppIcon = false
        guard UIApplication.shared.supportsAlternateIcons else {
            iconErrorMessage = "Alternate app icons are not supported on this device."
            return
        }
        let target: String? = choice.iconName.isEmpty ? nil : choice.iconName
        UIApplication.shared.setAlternateIconName(target) { error in
            DispatchQueue.main.async {
                if let error {
                    iconErrorMessage = "Could not switch app icon: \(error.localizedDescription)"
                } else {
                    settings.selectedAppIconName = choice.iconName
                }
            }
        }
    }
}
