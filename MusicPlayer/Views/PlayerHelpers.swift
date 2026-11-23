import AVKit
import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MovieTransferable: Transferable, Sendable {
    let url: URL
    let suggestedFileName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let fileName = received.file.lastPathComponent
            let destURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)_\(fileName)")
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: received.file, to: destURL)
            return Self(url: destURL, suggestedFileName: fileName)
        }
    }
}

struct PiPVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = false
        controller.showsPlaybackControls = true
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}

struct FFmpegVideoPlayerView: UIViewRepresentable {
    let renderView: UIView?

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.clipsToBounds = true
        attachRenderView(renderView, to: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        attachRenderView(renderView, to: uiView)
    }

    private func attachRenderView(_ target: UIView?, to container: UIView) {
        guard let target else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        if target.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            target.translatesAutoresizingMaskIntoConstraints = false
            target.contentMode = .scaleAspectFit
            container.addSubview(target)
            NSLayoutConstraint.activate([
                target.topAnchor.constraint(equalTo: container.topAnchor),
                target.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                target.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                target.trailingAnchor.constraint(equalTo: container.trailingAnchor)
            ])
        }
    }
}

struct AirPlayRoutePickerView: UIViewRepresentable {
    var prioritizesVideoDevices: Bool = false

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = prioritizesVideoDevices
        view.tintColor = UIColor.label
        view.activeTintColor = UIColor(Color.accentColor)
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.prioritizesVideoDevices = prioritizesVideoDevices
    }
}

struct MediaArtworkView: View {
    @Environment(AppSettings.self) private var settings
    let item: MediaItem
    let image: UIImage?
    var cornerRadius: CGFloat = 12
    var iconSize: CGFloat = 22

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if settings.useCustomAppIcon, let customIcon = settings.customAppIconImage {
                Image(uiImage: customIcon)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: item.isVideo
                            ? [Color.indigo.opacity(0.85), Color.purple.opacity(0.85)]
                            : [Color.accentColor.opacity(0.85), Color.cyan.opacity(0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: item.isVideo ? "film.fill" : "music.note")
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct EditTrackInfoSheet: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(\.dismiss) private var dismiss

    let item: MediaItem

    @State private var titleText: String
    @State private var artistText: String
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var pickedCover: UIImage?
    @State private var removeCustomCover = false
    @State private var showVerifySheet = false

    init(item: MediaItem) {
        self.item = item
        self._titleText = State(initialValue: item.metadataTitle ?? item.name)
        self._artistText = State(initialValue: item.artist ?? "")
    }

    private var previewImage: UIImage? {
        if removeCustomCover { return nil }
        return pickedCover ?? mediaManager.thumbnails[item.relativePath]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Cover Art") {
                    HStack(spacing: 16) {
                        MediaArtworkView(
                            item: item,
                            image: previewImage,
                            cornerRadius: 14,
                            iconSize: 28
                        )
                        .frame(width: 84, height: 84)

                        VStack(alignment: .leading, spacing: 8) {
                            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                Label("Change Cover", systemImage: "photo")
                            }
                            .buttonStyle(.bordered)

                            if previewImage != nil {
                                Button(role: .destructive) {
                                    pickedCover = nil
                                    removeCustomCover = true
                                } label: {
                                    Text("Reset Cover")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Track Info") {
                    TextField("Title", text: $titleText)
                    TextField("Artist", text: $artistText)

                    Button {
                        showVerifySheet = true
                    } label: {
                        Label("Auto-Verify via Lyrics & Catalog", systemImage: "checkmark.seal")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .navigationTitle("Edit Info")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showVerifySheet) {
                VerifyTrackArtistSheet(item: item) { confirmedArtist, confirmedTitle in
                    artistText = confirmedArtist
                    titleText = confirmedTitle
                    dismiss()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        mediaManager.updateTrackInfo(
                            for: item,
                            title: titleText,
                            artist: artistText,
                            coverImage: pickedCover,
                            removeCustomCover: removeCustomCover
                        )
                        dismiss()
                    }
                }
            }
            .onChange(of: selectedPhoto) { _, newValue in
                guard let newValue else { return }
                Task {
                    if let data = try? await newValue.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            pickedCover = image
                            removeCustomCover = false
                        }
                    }
                }
            }
        }
    }
}

struct AppThemeBackgroundView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if settings.hasCustomBackground {
            GeometryReader { proxy in
                ZStack {
                    if settings.useCustomBackgroundColor {
                        settings.customBackgroundColor
                    } else {
                        Color(.systemBackground)
                    }

                    if let bgImage = settings.customBackgroundImage {
                        Image(uiImage: bgImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                            .blur(radius: settings.backgroundBlurEnabled ? 10 : 0)

                        if settings.useCustomBackgroundColor {
                            settings.customBackgroundColor
                                .opacity(settings.backgroundDimOpacity)
                        } else if settings.backgroundDimOpacity > 0 {
                            Color.black
                                .opacity(settings.backgroundDimOpacity)
                        }
                    }
                }
            }
            .ignoresSafeArea()
        }
    }
}

struct CustomTextStyleModifier: ViewModifier {
    @Environment(AppSettings.self) private var settings

    func body(content: Content) -> some View {
        if settings.hasCustomTextColor {
            let color = settings.customTextColor
            content
                .foregroundStyle(color, color.opacity(0.76), color.opacity(0.52))
        } else {
            content
        }
    }
}

struct AppThemeContainerModifier: ViewModifier {
    @Environment(AppSettings.self) private var settings

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(settings.hasCustomBackground ? .hidden : .automatic)
            .background {
                AppThemeBackgroundView()
            }
            .modifier(CustomTextStyleModifier())
    }
}

struct MiniPlayerInsetModifier: ViewModifier {
    @Environment(MediaManager.self) private var mediaManager
    @Binding var showPlayerSheet: Bool
    @State private var showQueueSheet = false

    func body(content: Content) -> some View {
        content
            .modifier(AppThemeContainerModifier())
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    if let status = mediaManager.statusMessage {
                        Text(status)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThickMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    MiniPlayerBar(
                        onExpand: { showPlayerSheet = true },
                        onQueueTap: { showQueueSheet = true }
                    )
                }
            }
            .sheet(isPresented: $showQueueSheet) {
                UserQueueSheetView()
            }
    }
}

extension View {
    func miniPlayerInset(showPlayerSheet: Binding<Bool>) -> some View {
        modifier(MiniPlayerInsetModifier(showPlayerSheet: showPlayerSheet))
    }

    func applyAppTheme() -> some View {
        modifier(AppThemeContainerModifier())
    }

    func applyCustomTextStyle() -> some View {
        modifier(CustomTextStyleModifier())
    }
}
