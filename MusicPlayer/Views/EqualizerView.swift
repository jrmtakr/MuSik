import SwiftUI

struct EqualizerView: View {
    @Environment(MediaManager.self) private var mediaManager
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    private var eq: EqualizerAudioPlayer {
        mediaManager.equalizerPlayer
    }

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if mediaManager.currentItem?.isVideo == true {
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(Color.accentColor)
                            Text("Equalizer applies to audio tracks. Videos use native AVPlayer for video & PiP.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    Toggle(isOn: Binding(
                        get: { eq.isEnabled },
                        set: { eq.setEnabled($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("5-Band Equalizer")
                                .font(.headline)
                            Text(eq.isEnabled ? "Preset: \(eq.selectedPreset.rawValue)" : "Bypassed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    presetsStrip

                    faderBoard

                    Text("Drag any band between -12 dB and +12 dB. Double-tap a fader to reset it to 0 dB.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $settings.crossfadeEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Fade Between Songs (Crossfade)")
                                    .font(.headline)
                                Text(settings.crossfadeEnabled
                                     ? String(format: "%.1f sec smooth overlap", settings.crossfadeDurationSeconds)
                                     : "Off — songs play back-to-back")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if settings.crossfadeEnabled {
                            VStack(spacing: 4) {
                                HStack {
                                    Text("Fade Time")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(String(format: "%.1fs", settings.crossfadeDurationSeconds))
                                        .font(.caption.monospacedDigit().weight(.bold))
                                        .foregroundStyle(Color.accentColor)
                                }
                                Slider(value: $settings.crossfadeDurationSeconds, in: 1...12, step: 0.5)
                            }
                        }
                    }
                    .padding(16)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(16)
            }
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") {
                        eq.reset()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var presetsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(EqualizerPreset.selectablePresets) { preset in
                    let isSelected = eq.selectedPreset == preset && eq.isEnabled
                    Button {
                        eq.applyPreset(preset)
                    } label: {
                        Text(preset.rawValue)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
                            )
                            .foregroundStyle(isSelected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var faderBoard: some View {
        HStack(spacing: 12) {
            ForEach(Array(eq.frequencies.indices), id: \.self) { index in
                let gain = eq.bandGains[index]
                VStack(spacing: 10) {
                    Text(formattedGain(gain))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(eq.isEnabled ? .primary : .secondary)

                    EqualizerBandFader(
                        gain: Binding(
                            get: { eq.bandGains[index] },
                            set: { eq.setBandGain(bandIndex: index, gain: $0) }
                        ),
                        isEnabled: eq.isEnabled
                    )
                    .frame(height: 220)

                    Text(eq.frequencyLabels[index])
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func formattedGain(_ gain: Float) -> String {
        if abs(gain) < 0.05 { return "0.0 dB" }
        return String(format: "%+.1f dB", gain)
    }
}

private struct EqualizerBandFader: View {
    @Binding var gain: Float
    let isEnabled: Bool

    var body: some View {
        GeometryReader { proxy in
            let height = max(proxy.size.height, 1)
            let midY = height / 2
            let normalized = CGFloat((12 - gain) / 24) // +12 dB at top (0), -12 dB at bottom (1)
            let thumbY = min(max(normalized * height, 10), height - 10)

            ZStack {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 6)

                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 18, height: 1)
                    .position(x: proxy.size.width / 2, y: midY)

                let fillTop = min(midY, thumbY)
                let fillHeight = abs(thumbY - midY)
                Rectangle()
                    .fill(isEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 6, height: fillHeight)
                    .position(x: proxy.size.width / 2, y: fillTop + fillHeight / 2)

                Circle()
                    .fill(isEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                    .position(x: proxy.size.width / 2, y: thumbY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let clampedY = min(max(value.location.y, 0), height)
                        let rawGain = Float(12 - (clampedY / height) * 24)
                        let snapped = abs(rawGain) < 0.45 ? 0 : (rawGain * 2).rounded() / 2
                        gain = max(-12, min(12, snapped))
                    }
            )
            .onTapGesture(count: 2) {
                gain = 0
            }
        }
    }
}
