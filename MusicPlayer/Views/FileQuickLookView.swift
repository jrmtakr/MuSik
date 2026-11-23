import QuickLook
import SwiftUI

struct FileQuickLookView: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        if context.coordinator.fileURL != fileURL {
            context.coordinator.fileURL = fileURL
            uiViewController.reloadData()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var fileURL: URL

        init(fileURL: URL) {
            self.fileURL = fileURL
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            fileURL as NSURL
        }
    }
}

struct QuickLookTarget: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let fileURL: URL
}

struct QuickLookSheetView: View {
    @Environment(\.dismiss) private var dismiss
    let target: QuickLookTarget

    var body: some View {
        NavigationStack {
            FileQuickLookView(fileURL: target.fileURL)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(target.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: target.fileURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
        }
    }
}
