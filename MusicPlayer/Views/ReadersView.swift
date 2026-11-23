import SwiftUI
import UIKit

struct ImageReaderTarget: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let files: [LocalFile]
    let initialIndex: Int
}

struct ImageReaderView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    let target: ImageReaderTarget
    @State private var currentIndex: Int

    init(target: ImageReaderTarget) {
        self.target = target
        self._currentIndex = State(initialValue: target.initialIndex)
    }

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Group {
                if target.files.isEmpty {
                    ContentUnavailableView("No Images", systemImage: "photo")
                } else if settings.readingDirection == .scroll {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(target.files.enumerated()), id: \.element.id) { idx, file in
                                ReaderPageImage(url: file.fileURL)
                                    .onAppear {
                                        currentIndex = idx
                                    }
                            }
                        }
                    }
                    .background(Color.black)
                } else {
                    TabView(selection: $currentIndex) {
                        ForEach(Array(target.files.enumerated()), id: \.element.id) { idx, file in
                            ZoomableImagePage(url: file.fileURL)
                                .tag(idx)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .automatic))
                    .background(Color.black)
                }
            }
            .navigationTitle("\(target.title) (\(min(currentIndex + 1, max(target.files.count, 1)))/\(target.files.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Reading Direction", selection: $settings.readingDirection) {
                            ForEach(ReadingDirection.allCases) { dir in
                                Label(
                                    dir.rawValue,
                                    systemImage: dir == .scroll ? "arrow.up.and.down" : "book.pages"
                                )
                                .tag(dir)
                            }
                        }
                    } label: {
                        Label(
                            settings.readingDirection.rawValue,
                            systemImage: settings.readingDirection == .scroll ? "scroll" : "book.pages"
                        )
                    }

                    if target.files.indices.contains(currentIndex) {
                        ShareLink(item: target.files[currentIndex].fileURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }
}

private struct ReaderPageImage: View {
    let url: URL

    var body: some View {
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
        } else {
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .frame(height: 240)
        }
    }
}

private struct ZoomableImagePage: View {
    let url: URL
    @State private var scale: CGFloat = 1.0

    var body: some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                ReaderPageImage(url: url)
                    .frame(width: proxy.size.width * scale, height: proxy.size.height * scale)
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scale = scale > 1.1 ? 1.0 : 2.0
                        }
                    }
            }
        }
    }
}

struct TextStoryReaderView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    let file: LocalFile
    @State private var textContent: String = ""

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            ScrollView {
                Text(textContent)
                    .font(.system(size: settings.readerFontSize))
                    .foregroundStyle(settings.readerDarkTheme ? Color(white: 0.9) : Color(white: 0.12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .textSelection(.enabled)
            }
            .background(settings.readerDarkTheme ? Color(red: 0.08, green: 0.08, blue: 0.1) : Color(red: 0.98, green: 0.96, blue: 0.92))
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        settings.readerFontSize = max(12, settings.readerFontSize - 2)
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                    }

                    Button {
                        settings.readerFontSize = min(30, settings.readerFontSize + 2)
                    } label: {
                        Image(systemName: "textformat.size.larger")
                    }

                    Button {
                        settings.readerDarkTheme.toggle()
                    } label: {
                        Image(systemName: settings.readerDarkTheme ? "sun.max.fill" : "moon.fill")
                    }

                    ShareLink(item: file.fileURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .onAppear {
                textContent = loadText()
            }
        }
    }

    private func loadText() -> String {
        guard let data = try? Data(contentsOf: file.fileURL) else {
            return "Unable to read file."
        }
        if file.fileExtension == "rtf",
           let attr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
           ) {
            return attr.string
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? "Unsupported text encoding."
    }
}
