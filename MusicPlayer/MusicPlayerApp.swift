import SwiftUI

@main
struct MusicPlayerApp: App {
    @State private var mediaManager = MediaManager.shared
    @State private var wifiServer = WiFiTransferServer()
    @State private var sleepTimer = SleepTimerManager()
    @State private var settings = AppSettings()
    @State private var browserStore = BrowserStore()
    @State private var downloader = WebMediaDownloader()

    @State private var showPlayerSheet = false
    @State private var quickLookTarget: QuickLookTarget?

    var body: some Scene {
        WindowGroup {
            ContentView(showPlayerSheet: $showPlayerSheet, quickLookTarget: $quickLookTarget)
                .environment(mediaManager)
                .environment(wifiServer)
                .environment(sleepTimer)
                .environment(settings)
                .environment(browserStore)
                .environment(downloader)
                .task {
                    LocalMediaCacheProxy.shared.start()
                    wifiServer.onFileReceived = { tempURL, fileName, folderPath in
                        mediaManager.importTemporaryFile(from: tempURL, preferredFileName: fileName, inFolder: folderPath)
                    }
                    wifiServer.onLibraryChanged = {
                        mediaManager.loadLocalFiles()
                    }
                }
                .onOpenURL { url in
                    switch mediaManager.importAnyFile(from: url) {
                    case .media(let item):
                        mediaManager.play(item)
                        showPlayerSheet = true
                    case .document(let file):
                        quickLookTarget = QuickLookTarget(title: file.name, fileURL: file.fileURL)
                    case .folder:
                        break
                    case nil:
                        break
                    }
                }
        }
    }
}
