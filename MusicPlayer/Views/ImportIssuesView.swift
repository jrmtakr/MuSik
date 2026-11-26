import SwiftUI
import UIKit

/// Shows every song/video in a URL playlist import that failed or was stopped, why it failed,
/// which step failed, and lets the user retry one item or all of them.
struct ImportIssuesView: View {
    @Environment(PlaylistImportManager.self) private var playlistImportManager
    @Environment(\.dismiss) private var dismiss

    let jobID: UUID

    @State private var reasonFilter: PlaylistImportFailureReason?
    @State private var expandedTrackIDs: Set<UUID> = []
    @State private var copiedReport = false

    private var job: PlaylistImportJob? {
        playlistImportManager.jobs.first(where: { $0.id == jobID })
    }

    private var problemTracks: [PlaylistImportTrackJob] {
        guard let job else { return [] }
        return job.tracks.filter { $0.status == .failed || $0.status == .cancelled }
    }

    private var failedTracks: [PlaylistImportTrackJob] {
        problemTracks.filter { $0.status == .failed }
    }

    private var stoppedTracks: [PlaylistImportTrackJob] {
        problemTracks.filter { $0.status == .cancelled }
    }

    private struct ReasonCount: Identifiable {
        let reason: PlaylistImportFailureReason
        let count: Int
        var id: String { reason.rawValue }
    }

    private var reasonCounts: [ReasonCount] {
        var counts: [PlaylistImportFailureReason: Int] = [:]
        for t in failedTracks {
            counts[t.failureReason ?? .other, default: 0] += 1
        }
        return counts
            .map { ReasonCount(reason: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    private var visibleFailedTracks: [PlaylistImportTrackJob] {
        guard let reasonFilter else { return failedTracks }
        return failedTracks.filter { ($0.failureReason ?? .other) == reasonFilter }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let job {
                    List {
                        summarySection(job)
                        if !reasonCounts.isEmpty {
                            reasonsSection
                        }
                        if !visibleFailedTracks.isEmpty {
                            Section {
                                ForEach(visibleFailedTracks) { track in
                                    trackRow(track, job: job)
                                }
                            } header: {
                                Text(reasonFilter.map { "Failed — \($0.title) (\(visibleFailedTracks.count))" }
                                     ?? "Failed (\(failedTracks.count))")
                            }
                        }
                        if !stoppedTracks.isEmpty {
                            Section {
                                ForEach(stoppedTracks.prefix(300)) { track in
                                    trackRow(track, job: job)
                                }
                                if stoppedTracks.count > 300 {
                                    Text("+\(stoppedTracks.count - 300) more stopped tracks")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } header: {
                                Text("Stopped before finishing (\(stoppedTracks.count))")
                            } footer: {
                                Text("These weren't broken — the import was stopped before they were downloaded. Retry picks them back up.")
                            }
                        }
                        if problemTracks.isEmpty {
                            Section {
                                Label("No failed or stopped items in this import.", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Import not found", systemImage: "questionmark.folder")
                }
            }
            .navigationTitle("Import Issues")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            if let job { UIPasteboard.general.string = report(for: job) }
                            copiedReport = true
                        } label: {
                            Label("Copy Report", systemImage: "doc.on.doc")
                        }
                        if let job {
                            ShareLink(item: report(for: job)) {
                                Label("Share Report", systemImage: "square.and.arrow.up")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert("Report copied", isPresented: $copiedReport) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    // MARK: - Sections

    private func summarySection(_ job: PlaylistImportJob) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(job.playlistName)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 14) {
                    stat("\(job.completedCount)", "saved", .green)
                    stat("\(job.skippedCount)", "already had", .blue)
                    stat("\(job.failedCount)", "failed", .red)
                    if job.cancelledCount > 0 {
                        stat("\(job.cancelledCount)", "stopped", .orange)
                    }
                }
                Text("Format: \(job.preferredFormat.displayTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let identified = job.identifiedCount, identified > 0 {
                    Label("\(identified) songs auto-identified (title, artist, album, cover)", systemImage: "waveform.badge.magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }
                if let discoveryError = job.discoveryError {
                    Label("Playlist loading stopped early: \(discoveryError)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if job.isCancelled && job.discoveryCompleted == false {
                    Label(job.allowsRediscovery == false
                          ? "Import was stopped before the whole playlist loaded. Re-import the link to get the rest."
                          : "Import was stopped before the whole playlist loaded. Retry also loads the rest of the playlist.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            if job.canRetry {
                Button {
                    playlistImportManager.retryFailedTracks(inJobID: job.id)
                } label: {
                    Label(retryAllTitle(job), systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var reasonsSection: some View {
        Section("Why they failed") {
            ForEach(reasonCounts) { entry in
                let reason = entry.reason
                let count = entry.count
                Button {
                    reasonFilter = (reasonFilter == reason) ? nil : reason
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: reason.systemImage)
                            .foregroundStyle(.red)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reason.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(reason.suggestion)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(count)")
                            .font(.subheadline.monospacedDigit().weight(.bold))
                            .foregroundStyle(reasonFilter == reason ? Color.accentColor : .secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            if reasonFilter != nil {
                Button("Show all reasons") { reasonFilter = nil }
                    .font(.caption)
            }
        }
    }

    private func trackRow(_ track: PlaylistImportTrackJob, job: PlaylistImportJob) -> some View {
        let isExpanded = expandedTrackIDs.contains(track.id)
        let isStopped = track.status == .cancelled
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: job.preferredFormat == .audioOnly ? "music.note" : "film")
                    .foregroundStyle(isStopped ? Color.orange : Color.red)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title.isEmpty ? "Untitled" : track.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    Text([track.artist.isEmpty ? "Unknown Artist" : track.artist, track.durationText]
                        .compactMap { $0 }
                        .joined(separator: " • "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if isStopped {
                        Text("Stopped — not downloaded yet")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    } else {
                        Text((track.failureReason ?? .other).title + (track.failureStage.map { " · \($0)" } ?? ""))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    playlistImportManager.retryTrack(jobID: job.id, trackID: track.id)
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Retry \(track.title)")
            }

            if !isStopped {
                Button(isExpanded ? "Hide details" : "Details") {
                    if isExpanded { expandedTrackIDs.remove(track.id) } else { expandedTrackIDs.insert(track.id) }
                }
                .font(.caption2)
                .buttonStyle(.borderless)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        if let message = track.errorMessage, !message.isEmpty {
                            Text(message)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                        if let vid = track.youtubeVideoID, !vid.isEmpty {
                            Text("YouTube ID: \(vid)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Text("Attempts: \(max(track.totalAttempts ?? 0, track.retryCount + 1))\(track.resolvedViaBrowser ? " • used built-in browser" : "")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let last = track.lastAttemptAt {
                            Text("Last tried \(last.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text((track.failureReason ?? .other).suggestion)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.title3.monospacedDigit().weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func retryAllTitle(_ job: PlaylistImportJob) -> String {
        var parts: [String] = []
        if job.failedCount > 0 { parts.append("\(job.failedCount) failed") }
        if job.isCancelled && job.cancelledCount > 0 { parts.append("\(job.cancelledCount) stopped") }
        return parts.isEmpty ? "Restart Import" : "Retry \(parts.joined(separator: " + "))"
    }

    private func report(for job: PlaylistImportJob) -> String {
        var lines: [String] = []
        lines.append("Import report: \(job.playlistName)")
        lines.append("Source: \(job.sourceURLString)")
        lines.append("Format: \(job.preferredFormat.displayTitle)")
        lines.append("Saved \(job.completedCount) • Already had \(job.skippedCount) • Failed \(job.failedCount) • Stopped \(job.cancelledCount)")
        lines.append("")
        for track in failedTracks {
            let who = track.artist.isEmpty ? "" : "\(track.artist) - "
            let reason = (track.failureReason ?? .other).title
            let stage = track.failureStage.map { " [\($0)]" } ?? ""
            let vid = track.youtubeVideoID.map { " (yt:\($0))" } ?? ""
            lines.append("✗ \(who)\(track.title)\(vid): \(reason)\(stage) — \(track.errorMessage ?? "")")
        }
        if !stoppedTracks.isEmpty {
            lines.append("")
            lines.append("Stopped before download: \(stoppedTracks.count)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Wrapper so a job ID can drive `.sheet(item:)`.
struct IdentifiedUUID: Identifiable, Hashable {
    let id: UUID
}

/// Compact line under each import job: what failed / stopped, plus a button to open the full report.
struct ImportJobIssuesBar: View {
    let job: PlaylistImportJob
    let onShowIssues: () -> Void

    var body: some View {
        let failed = job.failedCount
        let stopped = job.isCancelled ? job.cancelledCount : 0
        let identified = job.identifiedCount ?? 0
        if failed > 0 || stopped > 0 || identified > 0 || job.discoveryError != nil {
            HStack(spacing: 8) {
                if identified > 0 {
                    Label("\(identified) identified", systemImage: "waveform.badge.magnifyingglass")
                        .foregroundStyle(.purple)
                }
                if failed > 0 {
                    Label(topReasonText(failed: failed), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else if stopped > 0 {
                    Label("\(stopped) stopped", systemImage: "stop.circle")
                        .foregroundStyle(.orange)
                } else if job.discoveryError != nil {
                    Label("Playlist loading failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
                if failed > 0 || stopped > 0 || job.discoveryError != nil {
                    Button("See why", action: onShowIssues)
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }
            .font(.caption2)
        }
    }

    private func topReasonText(failed: Int) -> String {
        var counts: [PlaylistImportFailureReason: Int] = [:]
        for t in job.tracks where t.status == .failed {
            counts[t.failureReason ?? .other, default: 0] += 1
        }
        guard let top = counts.max(by: { $0.value < $1.value }) else { return "\(failed) failed" }
        return counts.count == 1
            ? "\(failed) failed: \(top.key.title)"
            : "\(failed) failed (mostly \(top.key.title.lowercased()))"
    }
}
