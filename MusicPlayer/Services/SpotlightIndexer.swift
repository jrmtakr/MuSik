import CoreSpotlight
import Foundation
import UIKit
import UniformTypeIdentifiers

enum SpotlightIndexer {
    private static let domainIdentifier = "com.personal.musicplayer.library"

    @MainActor
    static func reindex(
        items: [MediaItem],
        playlists: [Playlist],
        otherFiles: [LocalFile],
        thumbnails: [String: UIImage],
        customMetadata: [String: MediaManager.CustomTrackMetadata]
    ) {
        var searchableItems: [CSSearchableItem] = []

        for item in items.prefix(400) {
            let attrs = CSSearchableItemAttributeSet(contentType: item.isVideo ? .movie : .audio)
            let custom = customMetadata[item.relativePath]
            let title = custom?.title?.isEmpty == false ? custom!.title! : item.displayTitle
            let artist = custom?.artist?.isEmpty == false ? custom!.artist! : (item.artist ?? "")

            attrs.title = title
            if !artist.isEmpty {
                attrs.artist = artist
            }
            attrs.contentDescription = "\(item.isVideo ? "Offline Video" : "Offline Song") • \(item.formattedFileSize)"
            var keywords = [title, item.fileExtension, "music", "offline", "music player"]
            if !artist.isEmpty { keywords.append(artist) }
            attrs.keywords = keywords
            if let dur = item.durationSeconds, dur.isFinite, dur > 0 {
                attrs.duration = NSNumber(value: dur)
            }
            if let img = thumbnails[item.relativePath], let jpeg = img.jpegData(compressionQuality: 0.55) {
                attrs.thumbnailData = jpeg
            }

            let entry = CSSearchableItem(
                uniqueIdentifier: "mp.song.\(item.relativePath)",
                domainIdentifier: domainIdentifier,
                attributeSet: attrs
            )
            searchableItems.append(entry)
        }

        for playlist in playlists {
            let attrs = CSSearchableItemAttributeSet(contentType: .content)
            attrs.title = playlist.name
            let count = playlist.itemFileNames.count
            attrs.contentDescription = "Offline Playlist • \(count) \(count == 1 ? "track" : "tracks")"
            attrs.keywords = [playlist.name, "playlist", "offline", "music player"]

            let entry = CSSearchableItem(
                uniqueIdentifier: "mp.playlist.\(playlist.id.uuidString)",
                domainIdentifier: domainIdentifier,
                attributeSet: attrs
            )
            searchableItems.append(entry)
        }

        for file in otherFiles.prefix(150) {
            let attrs = CSSearchableItemAttributeSet(contentType: .content)
            attrs.title = file.name
            attrs.contentDescription = "\(file.fileExtension.uppercased()) File • \(file.formattedFileSize)"
            attrs.keywords = [file.name, file.fileExtension, "document", "reader", "files"]

            let entry = CSSearchableItem(
                uniqueIdentifier: "mp.file.\(file.relativePath)",
                domainIdentifier: domainIdentifier,
                attributeSet: attrs
            )
            searchableItems.append(entry)
        }

        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { _ in
            guard !searchableItems.isEmpty else { return }
            index.indexSearchableItems(searchableItems) { _ in }
        }
    }

    @MainActor
    static func handleSpotlightActivity(
        _ activity: NSUserActivity,
        showPlayerSheet: inout Bool,
        quickLookTarget: inout QuickLookTarget?,
        requestedTab: inout AppTab
    ) {
        guard activity.activityType == CSSearchableItemActionType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else {
            return
        }

        let manager = MediaManager.shared

        if identifier.hasPrefix("mp.song.") {
            let relPath = String(identifier.dropFirst("mp.song.".count))
            if let item = manager.items.first(where: { $0.relativePath == relPath }) {
                manager.play(item)
                showPlayerSheet = true
                requestedTab = .playlists
            }
        } else if identifier.hasPrefix("mp.playlist.") {
            let rawID = String(identifier.dropFirst("mp.playlist.".count))
            if let uuid = UUID(uuidString: rawID),
               let playlist = manager.playlists.first(where: { $0.id == uuid }) {
                manager.playPlaylist(playlist)
                if manager.currentItem?.isVideo == true {
                    showPlayerSheet = true
                }
                requestedTab = .playlists
            }
        } else if identifier.hasPrefix("mp.file.") {
            let relPath = String(identifier.dropFirst("mp.file.".count))
            if let file = manager.otherFiles.first(where: { $0.relativePath == relPath }) {
                quickLookTarget = QuickLookTarget(title: file.name, fileURL: file.fileURL)
                requestedTab = .files
            }
        }
    }
}
