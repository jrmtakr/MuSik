import SwiftUI
import WebKit

struct SettingsView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(AppSettings.self) private var settings
    @Environment(BrowserStore.self) private var browserStore
    @Environment(WiFiTransferServer.self) private var wifiServer
    @Binding var showPlayerSheet: Bool

    @State private var showWiFiSheet = false
    @State private var showEqualizerSheet = false
    @State private var showClearedAlert = false

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
                }

                Section("Player & Tools") {
                    Toggle("Quick Access to Last Playlist", isOn: $settings.quickAccessLastPlaylist)

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

                Section("Browser & Ad-Block") {
                    Toggle("Enable Browser Ad-Block", isOn: $settings.adBlockEnabled)

                    Toggle("Web Page Dark Mode", isOn: $settings.webDarkModeEnabled)

                    Picker("Search Engine", selection: $settings.searchEngine) {
                        ForEach(SearchEngineOption.allCases) { engine in
                            Text(engine.rawValue).tag(engine)
                        }
                    }
                }

                Section("Video & Audio Caching") {
                    Toggle(
                        "Ask Before Caching",
                        isOn: Binding(
                            get: { settings.askBeforeCaching },
                            set: { settings.setAskBeforeCaching($0) }
                        )
                    )

                    Toggle(
                        "Auto-Cache Detected Media",
                        isOn: Binding(
                            get: { settings.autoCacheDetectedMedia },
                            set: { settings.setAutoCacheDetectedMedia($0) }
                        )
                    )

                    Picker("Duration Limit", selection: $settings.maxCacheDurationMinutes) {
                        Text("No Limit").tag(0)
                        ForEach(durationOptions.filter { $0 > 0 }, id: \.self) { mins in
                            Text("Under \(mins) min").tag(mins)
                        }
                    }
                }

                Section("Privacy & Data") {
                    Button(role: .destructive) {
                        browserStore.clearHistory()
                        let dataStore = WKWebsiteDataStore.default()
                        dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {}
                        }
                        showClearedAlert = true
                    } label: {
                        Label("Clear Browser History & Website Data", systemImage: "trash")
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
            .navigationTitle("Settings")
            .miniPlayerInset(showPlayerSheet: $showPlayerSheet)
            .sheet(isPresented: $showWiFiSheet) {
                WiFiTransferView()
            }
            .sheet(isPresented: $showEqualizerSheet) {
                EqualizerView()
            }
            .alert("Browser Data Cleared", isPresented: $showClearedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Browsing history, cookies, and website caches have been removed.")
            }
        }
    }
}
