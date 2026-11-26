import SwiftUI
import UniformTypeIdentifiers

struct LibraryBackupSheet: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(\.dismiss) private var dismiss

    @State private var backupService = LibraryBackupService.shared
    @State private var exportedDocument: ZipBackupFileDocument?
    @State private var showExporter = false
    @State private var showRestoreImporter = false
    @State private var pendingRestoreURL: URL?
    @State private var showRestoreModeConfirm = false
    @State private var showWiFiTransferSheet = false

    private var summary: LibraryBackupSummary {
        backupService.currentSummary()
    }

    var body: some View {
        NavigationStack {
            List {
                summarySection
                createBackupSection
                restoreBackupSection
                backupIdeasSection
            }
            .listStyle(.insetGrouped)
            .applyAppTheme()
            .navigationTitle("Library Backup & Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileExporter(
                isPresented: $showExporter,
                document: exportedDocument,
                contentType: .zip,
                defaultFilename: backupService.latestBackupURL?.deletingPathExtension().lastPathComponent ?? "MuseJRM-Backup"
            ) { result in
                if case .success(let savedURL) = result {
                    mediaManager.statusMessage = "Saved backup: \(savedURL.lastPathComponent)"
                }
            }
            .fileImporter(
                isPresented: $showRestoreImporter,
                allowedContentTypes: [.zip],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    pendingRestoreURL = url
                    showRestoreModeConfirm = true
                }
            }
            .confirmationDialog(
                "How should this backup be restored?",
                isPresented: $showRestoreModeConfirm,
                titleVisibility: .visible
            ) {
                Button("Merge (Keep Existing & Add Missing)") {
                    if let url = pendingRestoreURL {
                        Task { _ = await backupService.restoreBackup(from: url, mode: .merge) }
                    }
                }
                Button("Replace Whole Library", role: .destructive) {
                    if let url = pendingRestoreURL {
                        Task { _ = await backupService.restoreBackup(from: url, mode: .replace) }
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingRestoreURL = nil
                }
            } message: {
                Text("Merge keeps any newer songs you downloaded and restores everything missing. Replace resets your library to the backup snapshot.")
            }
            .sheet(isPresented: $showWiFiTransferSheet) {
                WiFiTransferView()
            }
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section("What Gets Backed Up") {
            HStack {
                statPill(value: "\(summary.audioCount)", label: "Songs", color: .blue)
                statPill(value: "\(summary.videoCount)", label: "Videos", color: .orange)
                statPill(value: "\(summary.playlistCount)", label: "Playlists", color: .purple)
                statPill(value: summary.formattedTotalSize, label: "Total", color: .green)
            }
            .padding(.vertical, 4)

            if let date = backupService.lastBackupDate {
                LabeledContent("Last Backup") {
                    Text(date, style: .relative) + Text(" ago")
                }
                .font(.caption)
                if let details = backupService.lastBackupDetails {
                    Text(details)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("No backup created yet on this device.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var createBackupSection: some View {
        Section {
            if backupService.isBackingUp {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text(backupService.statusText)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        Button("Cancel", role: .destructive) {
                            backupService.cancelActiveOperation()
                        }
                        .font(.caption.weight(.semibold))
                    }
                    ProgressView(value: backupService.progress)
                        .progressViewStyle(.linear)
                    HStack {
                        Text("\(backupService.completedFiles) / \(backupService.totalFiles) files")
                        Spacer()
                        Text("\(Int((backupService.progress * 100).rounded()))%")
                            .monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                Button {
                    Task {
                        if let url = await backupService.createFullBackup() {
                            exportedDocument = ZipBackupFileDocument(fileURL: url)
                        }
                    }
                } label: {
                    Label("Create Full Backup (.zip)", systemImage: "archivebox.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(backupService.isWorking || (summary.mediaCount == 0 && summary.otherFileCount == 0))
            }

            if let backupURL = backupService.latestBackupURL, !backupService.isWorking {
                Button {
                    exportedDocument = ZipBackupFileDocument(fileURL: backupURL)
                    showExporter = true
                } label: {
                    Label("Save to Files / iCloud / USB Drive", systemImage: "folder.badge.plus")
                }

                ShareLink(item: backupURL) {
                    Label("AirDrop / Share Backup ZIP", systemImage: "square.and.arrow.up")
                }
            }

            if let err = backupService.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Export Full Archive")
        } footer: {
            Text("Packs all songs, music videos, playlists, cover art, synced lyrics, and Shazam fingerprints into one portable ZIP.")
        }
    }

    private var restoreBackupSection: some View {
        Section {
            if backupService.isRestoring {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: backupService.progress)
                        .progressViewStyle(.linear)
                    Text(backupService.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                Button {
                    showRestoreImporter = true
                } label: {
                    Label("Restore from Backup ZIP...", systemImage: "arrow.counterclockwise.circle.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(backupService.isWorking)
            }

            Button {
                showWiFiTransferSheet = true
            } label: {
                Label("Backup to PC / Mac Browser over Wi-Fi", systemImage: "wifi")
            }
        } header: {
            Text("Restore & Computer Sync")
        }
    }

    private var backupIdeasSection: some View {
        Section("Best Ways to Keep Backups Safe") {
            ideaRow(
                icon: "icloud.fill",
                color: .blue,
                title: "iCloud Drive / Google Drive",
                detail: "Tap \"Save to Files\" and save directly into iCloud Drive or Google Drive so everything survives phone loss."
            )
            ideaRow(
                icon: "externaldrive.fill",
                color: .orange,
                title: "USB-C Flash Drive",
                detail: "Plug in any USB-C thumb drive and pick it in the Files save sheet for fast offline archival."
            )
            ideaRow(
                icon: "laptopcomputer",
                color: .green,
                title: "Wi-Fi Browser One-Click Backup",
                detail: "Open Wi-Fi Transfer on your computer and click \"Download Full Backup (.zip)\" to grab all songs & videos over local Wi-Fi."
            )
        }
    }

    private func statPill(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func ideaRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ZipBackupFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: fileURL, options: .immediate)
    }
}
