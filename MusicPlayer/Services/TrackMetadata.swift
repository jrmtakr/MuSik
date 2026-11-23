import AVFoundation
import UIKit

struct TrackMetadata {
    let title: String
    let artist: String
    let artwork: UIImage?
}

func extractMetadata(from url: URL) async -> TrackMetadata {
    let asset = AVURLAsset(url: url)
    var title = url.deletingPathExtension().lastPathComponent
    var artist = "Unknown Artist"
    var artwork: UIImage?

    if let metadata = try? await asset.load(.commonMetadata) {
        for item in metadata {
            if item.commonKey == .commonKeyTitle, let val = try? await item.load(.stringValue) {
                let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    title = trimmed
                }
            } else if item.commonKey == .commonKeyArtist, let val = try? await item.load(.stringValue) {
                let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    artist = trimmed
                }
            } else if item.commonKey == .commonKeyArtwork, let data = try? await item.load(.dataValue) {
                artwork = UIImage(data: data)
            }
        }
    }

    let ext = url.pathExtension.lowercased()
    let videoExtensions = MediaItem.allVideoExtensions
    if artwork == nil && (videoExtensions.contains(ext) || MediaItem.ffmpegAudioExtensions.contains(ext)) {
        if MediaItem.appleNativeVideoExtensions.contains(ext) && ext != "movpkg" {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            if let (cgImage, _) = try? await generator.image(at: .zero) {
                artwork = UIImage(cgImage: cgImage)
            }
        }
    }

    if artwork == nil || title == url.deletingPathExtension().lastPathComponent || artist == "Unknown Artist" {
        let info = await Task.detached(priority: .utility) {
            let meta = FFmpegMediaService.probeMetadata(for: url)
            let img = artwork == nil ? FFmpegMediaService.extractArtworkOrFrame(from: url, at: 1.0, maxDimension: 480) : nil
            return (meta, img)
        }.value
        if let meta = info.0 {
            if let metaTitle = meta.title, !metaTitle.isEmpty, title == url.deletingPathExtension().lastPathComponent {
                title = metaTitle
            }
            if let metaArtist = meta.artist, !metaArtist.isEmpty, artist == "Unknown Artist" {
                artist = metaArtist
            }
        }
        if artwork == nil {
            artwork = info.1
        }
    }

    return TrackMetadata(title: title, artist: artist, artwork: artwork)
}
