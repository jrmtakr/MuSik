import SwiftUI
import UIKit
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
    @State private var showEqualizerSheet = false
    @State private var showClearedAlert = false
    @State private var iconErrorMessage: String?

    private let durationOptions = [0, 10, 30, 60, 120]

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $settings.appearanceMode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    NavigationLink {
                        AppIconsPickerView(iconErrorMessage: $iconErrorMessage)
                    } label: {
                        HStack {
                            Label("App Icons", systemImage: "app.badge")
                            Spacer()
                            Text(currentIconLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Player & Tools") {
                    Toggle("Quick access to Last Playlist", isOn: $settings.quickAccessLastPlaylist)

                    Button {
                        showEqualizerSheet = true
                    } label: {
                        Label("5-Band Audio Equalizer", systemImage: "slider.vertical.3")
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
                            Text("Auto (\"Downloads\")").tag("")
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
                    Picker("Search Engine", selection: $settings.searchEngine) {
                        ForEach(SearchEngineOption.allCases) { engine in
                            Text(engine.rawValue).tag(engine)
                        }
                    }

                    Picker("Reading Direction", selection: $settings.readingDirection) {
                        ForEach(ReadingDirection.allCases) { dir in
                            Text(dir.rawValue).tag(dir)
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
                }
            }
            .navigationTitle("Setting")
            .miniPlayerInset(showPlayerSheet: $showPlayerSheet)
            .sheet(isPresented: $showWiFiSheet) {
                WiFiTransferView()
            }
            .sheet(isPresented: $showEqualizerSheet) {
                EqualizerView()
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
        AppIconChoice.all.first(where: { $0.iconName == settings.selectedAppIconName })?.title ?? "Default"
    }
}

private struct AppIconsPickerView: View {
    @Environment(AppSettings.self) private var settings
    @Binding var iconErrorMessage: String?

    var body: some View {
        List {
            ForEach(AppIconChoice.all) { choice in
                let isSelected = settings.selectedAppIconName == choice.iconName
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
        .navigationTitle("App Icons")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func applyIcon(_ choice: AppIconChoice) {
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
