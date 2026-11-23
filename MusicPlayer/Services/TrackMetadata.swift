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

    let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    if artwork == nil && videoExtensions.contains(url.pathExtension.lowercased()) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        if let (cgImage, _) = try? await generator.image(at: .zero) {
            artwork = UIImage(cgImage: cgImage)
        }
    }

    return TrackMetadata(title: title, artist: artist, artwork: artwork)
}
