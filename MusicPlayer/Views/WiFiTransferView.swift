import SwiftUI
import UIKit

struct WiFiTransferView: View {
    @Environment(WiFiTransferServer.self) private var wifiServer
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPort: UInt16 = 8080
    @State private var didCopyURL = false
    @State private var keepScreenAwake = true

    private let availablePorts: [UInt16] = [8080, 8081, 9000]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(wifiServer.isRunning ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 12, height: 12)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(wifiServer.isRunning ? "Server Running" : "Server Stopped")
                                .font(.headline)
                            Text(wifiServer.isRunning
                                 ? "Open the address below in a browser on the same Wi-Fi network."
                                 : "Start the server to upload or download files over Wi-Fi.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    if !wifiServer.isRunning {
                        Picker("Port", selection: $selectedPort) {
                            ForEach(availablePorts, id: \.self) { port in
                                Text("Port \(port)").tag(port)
                            }
                        }
                    }

                    Button {
                        if wifiServer.isRunning {
                            wifiServer.stop()
                        } else {
                            wifiServer.start(port: selectedPort)
                        }
                    } label: {
                        Label(
                            wifiServer.isRunning ? "Stop Wi-Fi Server" : "Start Wi-Fi Server",
                            systemImage: wifiServer.isRunning ? "stop.circle.fill" : "antenna.radiowaves.left.and.right"
                        )
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(wifiServer.isRunning ? .red : .accentColor)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                if wifiServer.isRunning {
                    Section("Web Uploader URL") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(wifiServer.serverAddress)
                                .font(.title3.monospaced().weight(.semibold))
                                .textSelection(.enabled)

                            HStack(spacing: 12) {
                                Button {
                                    UIPasteboard.general.string = wifiServer.serverAddress
                                    didCopyURL = true
                                    Task {
                                        try? await Task.sleep(for: .seconds(1.5))
                                        didCopyURL = false
                                    }
                                } label: {
                                    Label(didCopyURL ? "Copied!" : "Copy URL",
                                          systemImage: didCopyURL ? "checkmark" : "doc.on.doc")
                                        .font(.subheadline.weight(.medium))
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    wifiServer.refreshAddress()
                                } label: {
                                    Label("Refresh IP", systemImage: "arrow.clockwise")
                                        .font(.subheadline.weight(.medium))
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 4)

                        Toggle("Keep Screen Awake", isOn: $keepScreenAwake)
                    }
                }

                if let error = wifiServer.errorMessage {
                    Section("Error") {
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }

                Section("Recent Wi-Fi Uploads") {
                    if wifiServer.recentUploads.isEmpty {
                        Text("Files uploaded from your browser will appear here and in your Library automatically.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(wifiServer.recentUploads) { entry in
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(entry.fileName)
                                    .lineLimit(1)
                                Spacer()
                                Text(entry.uploadedAt, style: .time)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Wi-Fi Transfer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                selectedPort = wifiServer.port
                updateIdleTimer()
            }
            .onChange(of: wifiServer.isRunning) { _, _ in
                updateIdleTimer()
            }
            .onChange(of: keepScreenAwake) { _, _ in
                updateIdleTimer()
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = wifiServer.isRunning && keepScreenAwake
    }
}
